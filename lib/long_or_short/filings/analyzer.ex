defmodule LongOrShort.Filings.Analyzer do
  @moduledoc """
  Orchestrates the dilution-analysis pipeline for one Filing — Stage 3c
  of the LON-106 epic (LON-115).

  Ties together:

    * `LongOrShort.Filings.Filing` + `FilingRaw` (input)
    * `LongOrShort.Filings.Extractor` (LON-113, Stage 3a — LLM facts)
    * `LongOrShort.Filings.Scoring` + `SeverityRules` (LON-114, Stage 3b — verdict)
    * `LongOrShort.Filings.FilingAnalysis` (the persisted row)
    * `LongOrShort.Filings.Events` (PubSub broadcast)

  ## Single entry point

  Callers go through `LongOrShort.Filings.analyze_filing/1,2` (which
  delegates here). Workers, the future manual-trigger UI, and tests
  all flow through this function. Don't add a second public entry —
  if a new caller needs different behavior, route it through opts.

  ## Pipeline

      load Filing (with :ticker + :filing_raw)
        -> Extractor.extract
            error :filing_raw_missing | :not_supported | :no_relevant_content
                -> return error, do not persist (transient or out-of-scope)
            other error
                -> persist :rejected with the error reason, broadcast
            success
                -> Scoring.score(extraction, ticker_context)
                    :rejected (validation failed)
                        -> persist :rejected with full extraction + provenance
                    :high (with or without rule matches)
                        -> persist :high with all fields
        -> broadcast `{:new_filing_analysis, %FilingAnalysis{}}` on
           `"filings:analyses"` regardless of quality

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
      keep burning tokens. Manual re-trigger remains possible (upsert
      will overwrite).

  ## Errors returned to the caller

    * `{:error, {:filing_not_found, id}}` — unknown filing id
    * `{:error, :filing_raw_missing}` — body not yet fetched
    * `{:error, :not_supported}` — out-of-scope filing type
    * `{:error, :no_relevant_content}` — SectionFilter empty result
    * Any Ash error from the upsert (rare; persistence failure)

  Callers that want fire-and-forget semantics (workers) should ignore
  the error tuple beyond logging — the LLM-failure cases already
  persisted a `:rejected` row, and the transient cases are expected
  to clear on the next pass.
  """

  require Logger

  alias LongOrShort.AI
  alias LongOrShort.Accounts.SystemActor
  alias LongOrShort.Filings
  alias LongOrShort.Filings.{Events, Extractor, FilingAnalysis, Scoring}

  @analyzer_actor_name "filing-analyzer"

  @doc """
  Run extraction + scoring for a Filing and persist the result.

  ## Options

    * `:provider` — override the AI provider (test injection). Passed
      through to `Extractor.extract/2`.

  Returns the persisted (or upserted-over-existing) `FilingAnalysis`,
  or an error tuple. See moduledoc for the error taxonomy.
  """
  @spec analyze_filing(Ash.UUID.t() | Filings.Filing.t(), keyword()) ::
          {:ok, FilingAnalysis.t()} | {:error, term()}
  def analyze_filing(filing_or_id, opts \\ [])

  def analyze_filing(filing_id, opts) when is_binary(filing_id) do
    case load_filing(filing_id) do
      {:ok, filing} -> do_analyze(filing, opts)
      {:error, _} = err -> err
    end
  end

  def analyze_filing(%Filings.Filing{} = filing, opts) do
    # Even when the caller already has a Filing struct, reload to make
    # sure :ticker and :filing_raw are loaded under the analyzer actor.
    analyze_filing(filing.id, opts)
  end

  # ── Pipeline ────────────────────────────────────────────────────

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

  defp do_analyze(filing, opts) do
    extractor_opts = Keyword.put_new(opts, :actor, analyzer_actor())

    case Extractor.extract(filing, extractor_opts) do
      {:ok, %{extraction: extraction, provenance: provenance}} ->
        score_and_persist(filing, extraction, provenance)

      {:error, reason} ->
        handle_extract_error(filing, reason)
    end
  end

  defp score_and_persist(filing, extraction, provenance) do
    ticker_context = %{filing: filing, ticker: filing.ticker}
    score = Scoring.score(extraction, ticker_context)

    attrs =
      filing
      |> base_attrs()
      |> Map.merge(extraction_attrs(extraction))
      |> Map.merge(score_attrs(score))
      |> Map.merge(provenance_attrs(provenance))

    persist_and_broadcast(attrs)
  end

  defp handle_extract_error(_filing, {:filing_raw_missing, _id}) do
    {:error, :filing_raw_missing}
  end

  defp handle_extract_error(_filing, :not_supported), do: {:error, :not_supported}
  defp handle_extract_error(_filing, :no_relevant_content), do: {:error, :no_relevant_content}

  defp handle_extract_error(filing, reason) do
    Logger.warning(
      "[Filings.Analyzer] Extraction failed for filing #{filing.id}: #{inspect(reason)} — persisting :rejected"
    )

    attrs =
      filing
      |> base_attrs()
      |> Map.merge(extraction_failure_attrs(reason))

    persist_and_broadcast(attrs)
  end

  defp persist_and_broadcast(attrs) do
    case Filings.upsert_filing_analysis(attrs, actor: analyzer_actor()) do
      {:ok, analysis} ->
        Events.broadcast_analysis_ready(analysis)
        {:ok, analysis}

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
    # We persist a :rejected row but don't have extraction data. All
    # extraction-typed atoms get safe defaults from the resource
    # (:dilution_type and :pricing_method are not nullable, so set
    # them explicitly here).
    provider = AI.default_provider()

    %{
      dilution_type: :none,
      pricing_method: :unknown,
      has_anti_dilution_clause: false,
      has_death_spiral_convertible: false,
      is_reverse_split_proxy: false,
      dilution_severity: :none,
      matched_rules: [],
      severity_reason: nil,
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
