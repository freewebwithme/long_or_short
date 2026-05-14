defmodule LongOrShort.Filings.Analyzer do
  @moduledoc """
  Orchestrates the dilution-analysis pipeline. Stage 3c of the LON-106
  epic; split into two tiers in LON-134.

  ## Two-tier API (LON-134)

    * `extract_keywords/2` — Tier 1. LLM extraction; persists keywords
      + facts with `dilution_severity = nil`. Cheap proactive pass.
    * `score_severity/2` — Tier 2. Deterministic scoring via
      `SeverityRules`; fills the verdict on a Tier 1 row.
    * `analyze_filing/2` — orchestrator that calls both in sequence.
      Behavior-preserving alias of the pre-LON-134 entry point.

  Callers should always go through `LongOrShort.Filings.{...}` rather
  than reaching into this module directly.

  ## Pipeline

      Tier 1 (extract_keywords/2):
        load Filing (with :ticker + :filing_raw)
          -> Extractor.extract
              error :filing_raw_missing | :not_supported | :no_relevant_content
                  -> return error, do not persist (transient or out-of-scope)
              other error (LLM / validation)
                  -> persist Tier 1 :rejected row, broadcast
              success
                  -> persist Tier 1 row (extracted_keywords + facts
                     + :high quality + severity nil), broadcast

      Tier 2 (score_severity/2):
        load FilingAnalysis (with :filing + :filing.ticker)
          extraction_quality == :rejected
              -> short-circuit: severity = :none, matched_rules = [],
                 severity_reason = nil (matches pre-LON-134 row shape)
          else
              -> rebuild extraction from columns,
                 Scoring.score(extraction, %{filing:, ticker:})
              -> update Tier 2 attrs (may downgrade quality to
                 :rejected on scoring-side validation failure)
          -> broadcast

  Both tiers broadcast `{:new_filing_analysis, %FilingAnalysis{}}` on
  `\"filings:analyses\"`.

  ## Why persist on LLM-side errors but not on transient/out-of-scope errors

  Three goals pull in opposite directions:

    1. The watchlist worker (LON-115 Phase 1b) re-scans every 15 min
       for FilingRaws lacking a FilingAnalysis. If a row is never
       written, the worker keeps trying — fine for free skips, bad
       when each retry burns LLM tokens.
    2. Genuinely transient errors (`:filing_raw_missing`) should
       resolve themselves on the next pass once the body lands.
    3. Audit/cost analysis wants a row for every LLM call, including
       failed ones.

  Resolution:

    * `:filing_raw_missing` — body not fetched yet. Don't persist;
      the body fetcher (LON-119) will populate FilingRaw and the
      watchlist worker will pick it up next cycle.
    * `:not_supported` — Form 4 etc. live in a different pipeline
      (Stage 9). Don't persist; the worker queue should filter these
      out before queueing, but defense in depth.
    * `:no_relevant_content` — SectionFilter found no dilution-relevant
      sections. No LLM call was made, so retries are free. Don't
      persist; saves a row in the common DEF 14A case.
    * Anything else — `:no_tool_call`, `{:invalid_enum, _, _}`, AI
      provider errors — means the LLM ran (or tried to) and produced
      unusable output. Persist a `:rejected` row so the worker doesn't
      keep burning tokens. Manual re-trigger remains possible (Tier 1
      upsert overwrites).

  ## Errors

  `extract_keywords/2` and `analyze_filing/2`:

    * `{:error, {:filing_not_found, id}}` — unknown filing id
    * `{:error, :filing_raw_missing}` — body not yet fetched
    * `{:error, :not_supported}` — out-of-scope filing type
    * `{:error, :no_relevant_content}` — SectionFilter empty result
    * Any Ash error from the upsert (rare; persistence failure)

  `score_severity/2`:

    * `{:error, {:filing_analysis_not_found, id}}` — unknown analysis id
    * Any Ash error from the load / update (rare; persistence failure)

  Callers that want fire-and-forget semantics (workers) should ignore
  the error tuple beyond logging.
  """

  require Logger

  alias LongOrShort.AI
  alias LongOrShort.Accounts.SystemActor
  alias LongOrShort.Filings
  alias LongOrShort.Filings.{Events, Extractor, FilingAnalysis, Scoring}

  @analyzer_actor_name "filing-analyzer"

  # ── Orchestrator (back-compat) ──────────────────────────────────

  @doc """
  Run Tier 1 + Tier 2 in sequence. Used by `FilingAnalysisWorker`
  today; behavior-preserving alias of the pre-LON-134 entry point.
  """
  @spec analyze_filing(Ash.UUID.t() | Filings.Filing.t(), keyword()) ::
          {:ok, FilingAnalysis.t()} | {:error, term()}
  def analyze_filing(filing_or_id, opts \\ []) do
    # Suppress the Tier 1 broadcast — the orchestrator emits exactly one
    # `:new_filing_analysis` event per call (the final Tier 2 write),
    # matching pre-LON-134 behavior so downstream alerts don't double-fire.
    tier_1_opts = Keyword.put(opts, :broadcast?, false)

    with {:ok, tier_1_row} <- extract_keywords(filing_or_id, tier_1_opts) do
      score_severity(tier_1_row, opts)
    end
  end

  # ── Tier 1: extract_keywords ────────────────────────────────────

  @doc """
  Tier 1 — LLM extraction → persist `FilingAnalysis` with
  `dilution_severity = nil`. See moduledoc for the error taxonomy.
  """
  @spec extract_keywords(Ash.UUID.t() | Filings.Filing.t(), keyword()) ::
          {:ok, FilingAnalysis.t()} | {:error, term()}
  def extract_keywords(filing_or_id, opts \\ [])

  def extract_keywords(filing_id, opts) when is_binary(filing_id) do
    case load_filing(filing_id) do
      {:ok, filing} -> do_extract(filing, opts)
      {:error, _} = err -> err
    end
  end

  def extract_keywords(%Filings.Filing{} = filing, opts) do
    extract_keywords(filing.id, opts)
  end

  defp load_filing(filing_id) do
    case Filings.get_filing(filing_id,
           load: [:ticker, :filing_raw],
           actor: analyzer_actor()
         ) do
      {:ok, filing} -> {:ok, filing}
      {:error, %Ash.Error.Query.NotFound{}} -> {:error, {:filing_not_found, filing_id}}
      {:error, _} = err -> err
    end
  end

  defp do_extract(filing, opts) do
    extractor_opts = Keyword.put_new(opts, :actor, analyzer_actor())

    case Extractor.extract(filing, extractor_opts) do
      {:ok, %{extraction: extraction, provenance: provenance}} ->
        attrs = build_tier_1_success_attrs(filing, extraction, provenance)
        persist_tier_1(attrs, opts)

      {:error, reason} ->
        handle_extract_error(filing, reason, opts)
    end
  end

  defp build_tier_1_success_attrs(filing, extraction, provenance) do
    filing
    |> base_attrs()
    |> Map.merge(extraction_attrs(extraction))
    |> Map.merge(provenance_attrs(provenance))
    |> Map.put(:extracted_keywords, extraction)
    |> Map.put(:extraction_quality, :high)
    |> Map.put(:rejected_reason, nil)
  end

  defp handle_extract_error(_filing, {:filing_raw_missing, _id}, _opts) do
    {:error, :filing_raw_missing}
  end

  defp handle_extract_error(_filing, :not_supported, _opts), do: {:error, :not_supported}

  defp handle_extract_error(_filing, :no_relevant_content, _opts),
    do: {:error, :no_relevant_content}

  defp handle_extract_error(filing, reason, opts) do
    Logger.warning(
      "[Filings.Analyzer] Extraction failed for filing #{filing.id}: " <>
        "#{inspect(reason)} — persisting :rejected"
    )

    attrs =
      filing
      |> base_attrs()
      |> Map.merge(extraction_failure_attrs(reason))

    persist_tier_1(attrs, opts)
  end

  defp persist_tier_1(attrs, opts) do
    case Filings.upsert_filing_analysis_tier_1(attrs, actor: analyzer_actor()) do
      {:ok, analysis} ->
        if Keyword.get(opts, :broadcast?, true) do
          Events.broadcast_analysis_ready(analysis)
        end

        {:ok, analysis}

      {:error, _} = err ->
        err
    end
  end

  # ── Tier 2: score_severity ──────────────────────────────────────

  @doc """
  Tier 2 — score the Tier 1 row's extraction against `SeverityRules`
  and persist the verdict. Short-circuits to `severity = :none` when
  Tier 1 was rejected.
  """
  @spec score_severity(FilingAnalysis.t() | Ash.UUID.t(), keyword()) ::
          {:ok, FilingAnalysis.t()} | {:error, term()}
  def score_severity(analysis_or_id, opts \\ [])

  def score_severity(%FilingAnalysis{} = analysis, _opts) do
    do_score(analysis)
  end

  def score_severity(analysis_id, opts) when is_binary(analysis_id) do
    case load_analysis(analysis_id) do
      {:ok, analysis} -> score_severity(analysis, opts)
      {:error, _} = err -> err
    end
  end

  defp load_analysis(id) do
    case Filings.get_filing_analysis(id,
           actor: analyzer_actor(),
           not_found_error?: false
         ) do
      {:ok, nil} -> {:error, {:filing_analysis_not_found, id}}
      {:ok, analysis} -> {:ok, analysis}
      {:error, _} = err -> err
    end
  end

  defp do_score(%FilingAnalysis{extraction_quality: :rejected} = analysis) do
    # Tier 1 already rejected — nothing to score. Stamp severity = :none
    # so the row shape matches the pre-LON-134 rejected state.
    update_tier_2(analysis, %{
      dilution_severity: :none,
      matched_rules: [],
      severity_reason: nil
    })
  end

  defp do_score(%FilingAnalysis{} = analysis) do
    with {:ok, loaded} <- ensure_filing_loaded(analysis) do
      extraction = reconstruct_extraction(loaded)
      ticker_context = %{filing: loaded.filing, ticker: loaded.filing.ticker}
      score = Scoring.score(extraction, ticker_context)
      update_tier_2(loaded, score_attrs(score))
    end
  end

  defp ensure_filing_loaded(analysis) do
    Ash.load(analysis, [filing: [:ticker]], actor: analyzer_actor())
  end

  # Rebuilds the extraction map Scoring expects from the persisted
  # columns. Columns preserve atom keys + native types — except for
  # `:decimal` columns, which round-trip as `%Decimal{}` structs. The
  # pre-refactor flow passed raw LLM numbers (int/float) into
  # `Validation`, whose checks use `is_number/1` — `%Decimal{}` would
  # silently fail those guards and reject the row. Coerce decimals
  # back to floats here so Tier 2 behaves like the pre-refactor
  # combined flow.
  defp reconstruct_extraction(%FilingAnalysis{} = a) do
    %{
      dilution_type: a.dilution_type,
      deal_size_usd: decimal_to_number(a.deal_size_usd),
      share_count: a.share_count,
      pricing_method: a.pricing_method,
      pricing_discount_pct: decimal_to_number(a.pricing_discount_pct),
      warrant_strike: decimal_to_number(a.warrant_strike),
      warrant_term_years: a.warrant_term_years,
      atm_remaining_shares: a.atm_remaining_shares,
      atm_total_authorized_shares: a.atm_total_authorized_shares,
      shelf_total_authorized_usd: decimal_to_number(a.shelf_total_authorized_usd),
      shelf_remaining_usd: decimal_to_number(a.shelf_remaining_usd),
      convertible_conversion_price: decimal_to_number(a.convertible_conversion_price),
      has_anti_dilution_clause: a.has_anti_dilution_clause,
      has_death_spiral_convertible: a.has_death_spiral_convertible,
      is_reverse_split_proxy: a.is_reverse_split_proxy,
      reverse_split_ratio: a.reverse_split_ratio,
      summary: a.summary
    }
  end

  defp decimal_to_number(nil), do: nil
  defp decimal_to_number(%Decimal{} = d), do: Decimal.to_float(d)
  defp decimal_to_number(n) when is_number(n), do: n

  defp update_tier_2(analysis, tier_2_attrs) do
    case Filings.update_filing_analysis_tier_2(analysis, tier_2_attrs,
           actor: analyzer_actor()
         ) do
      {:ok, updated} ->
        Events.broadcast_analysis_ready(updated)
        {:ok, updated}

      {:error, _} = err ->
        err
    end
  end

  # ── Attrs builders ──────────────────────────────────────────────

  defp base_attrs(filing) do
    %{filing_id: filing.id, ticker_id: filing.ticker_id}
  end

  defp extraction_attrs(extraction) do
    %{
      dilution_type: extraction[:dilution_type],
      deal_size_usd: extraction[:deal_size_usd],
      share_count: extraction[:share_count],
      pricing_method: extraction[:pricing_method],
      pricing_discount_pct: extraction[:pricing_discount_pct],
      warrant_strike: extraction[:warrant_strike],
      warrant_term_years: extraction[:warrant_term_years],
      atm_remaining_shares: extraction[:atm_remaining_shares],
      atm_total_authorized_shares: extraction[:atm_total_authorized_shares],
      shelf_total_authorized_usd: extraction[:shelf_total_authorized_usd],
      shelf_remaining_usd: extraction[:shelf_remaining_usd],
      convertible_conversion_price: extraction[:convertible_conversion_price],
      has_anti_dilution_clause: extraction[:has_anti_dilution_clause] || false,
      has_death_spiral_convertible: extraction[:has_death_spiral_convertible] || false,
      is_reverse_split_proxy: extraction[:is_reverse_split_proxy] || false,
      reverse_split_ratio: extraction[:reverse_split_ratio],
      summary: extraction[:summary]
    }
  end

  defp score_attrs(%{extraction_quality: :rejected} = score) do
    %{
      dilution_severity: :none,
      matched_rules: [],
      severity_reason: score.reason,
      extraction_quality: :rejected,
      rejected_reason: format_rejection(score.rejection)
    }
  end

  defp score_attrs(%{extraction_quality: quality} = score) do
    %{
      dilution_severity: score.severity,
      matched_rules: score.matched_rules,
      severity_reason: score.reason,
      extraction_quality: quality,
      rejected_reason: nil
    }
  end

  defp provenance_attrs(%{model: model, provider: provider} = provenance) do
    %{
      provider: provider_name(provider),
      model: model,
      raw_response: %{"usage" => map_with_string_keys(provenance[:usage])}
    }
  end

  defp extraction_failure_attrs(reason) do
    # Tier 1 failure: no extraction data. Set the non-nullable
    # extraction columns to safe defaults; Tier 2 fields are left
    # untouched — the orchestrator (or a later explicit Tier 2 call)
    # handles severity = :none for rejected rows.
    provider = AI.default_provider()

    %{
      extracted_keywords: nil,
      dilution_type: :none,
      pricing_method: :unknown,
      has_anti_dilution_clause: false,
      has_death_spiral_convertible: false,
      is_reverse_split_proxy: false,
      flags: [],
      extraction_quality: :rejected,
      rejected_reason: format_extract_error(reason),
      provider: provider_name(provider),
      model: "unknown",
      raw_response: %{"error" => inspect(reason)}
    }
  end

  # ── Formatting helpers ─────────────────────────────────────────

  defp format_rejection(%{check: check, context: ctx}) do
    "validation:#{check}: #{inspect(ctx)}"
  end

  defp format_rejection(_), do: nil

  defp format_extract_error(:no_tool_call), do: "extractor:no_tool_call"

  defp format_extract_error({:invalid_enum, field, value}),
    do: "extractor:invalid_enum:#{field}=#{inspect(value)}"

  defp format_extract_error(reason), do: "extractor:#{inspect(reason)}"

  defp provider_name(provider) when is_atom(provider), do: inspect(provider)
  defp provider_name(provider) when is_binary(provider), do: provider
  defp provider_name(other), do: inspect(other)

  defp map_with_string_keys(nil), do: nil

  defp map_with_string_keys(map) when is_map(map) do
    Enum.into(map, %{}, fn {k, v} -> {to_string(k), v} end)
  end

  defp analyzer_actor, do: SystemActor.new(@analyzer_actor_name)
end
