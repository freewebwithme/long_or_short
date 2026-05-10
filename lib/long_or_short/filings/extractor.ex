defmodule LongOrShort.Filings.Extractor do
  @moduledoc """
  LLM-driven dilution-fact extraction for SEC filings (LON-113, Stage 3a).

  Orchestrates the three-step extraction pipeline:

    1. **Pre-filter** — `LongOrShort.Filings.SectionFilter` reduces the
       full filing body to dilution-relevant sections (typical ~10×
       token reduction on S-1 filings).
    2. **Tier routing** — `LongOrShort.Filings.Extractor.Router`
       selects a `:cheap | :complex` tier based on filing type, then
       resolves the tier into a concrete model ID for the active
       AI provider.
    3. **LLM call + validation** — sends a stable system prompt + tool
       schema (cached) plus the per-filing user message. Parses the
       tool call, validates enum values, returns structured facts.

  ## Public API

      Extractor.extract(filing, opts \\\\ [])
        => {:ok, %{filing_id, extraction, provenance}} | {:error, reason}

  This stage **does not persist** anything — Stage 3c (LON-115) owns
  the `FilingAnalysis` resource. The returned `%{provenance: ...}`
  carries the model ID, tier, provider, and token usage so that
  Stage 3c can record them verbatim.

  ## Error reasons

  Beyond errors propagated from the AI provider:

    * `{:filing_raw_missing, filing_id}` — the Filing has no
      associated `FilingRaw` (body never fetched). Caller decides
      whether to retry after triggering a fetch.
    * `:not_supported` — `SectionFilter` rejected the filing type
      (Form 4 has its own pipeline in Stage 9).
    * `:no_relevant_content` — `SectionFilter` returned an empty
      list (e.g. a routine DEF 14A with no reverse-split keywords).
      No LLM call is made; caller can record this as "not analyzed"
      without spending tokens.
    * `:no_tool_call` — the LLM returned text instead of invoking
      the tool. Treated as an extraction failure.
    * `{:invalid_enum, field, value}` — LLM returned an enum string
      not in the schema's allowed list.
  """

  alias LongOrShort.AI
  alias LongOrShort.AI.Prompts
  alias LongOrShort.AI.Tools
  alias LongOrShort.Accounts.SystemActor
  alias LongOrShort.Filings
  alias LongOrShort.Filings.{Filing, Extractor.Router, SectionFilter}

  # Closed enum lists registered as compile-time atoms. Mirror the
  # string lists in `Tools.FilingExtraction` — kept in sync via tests.
  @dilution_type_atoms ~w(atm s1_offering s3_shelf pipe warrant_exercise convertible_conversion reverse_split none)a
  @pricing_method_atoms ~w(fixed market_minus_pct vwap_based unknown)a

  # Per-section character cap for SectionFilter output. ~8K chars ≈
  # ~2K tokens. Six full sections fit in ~12K tokens, comfortably
  # below LLM context limits and small enough to keep cost predictable
  # even on multi-megabyte prospectuses (LON-119). The truncated
  # marker `[... truncated]` signals to the LLM that the section was
  # cut, allowing it to reason about completeness.
  @max_section_chars 8_000

  @typedoc "Successful extraction result."
  @type result :: %{
          filing_id: Ash.UUID.t(),
          extraction: map(),
          provenance: %{
            model: String.t(),
            tier: Router.tier(),
            provider: module(),
            usage: map()
          }
        }

  @doc """
  Extract dilution facts from a stored filing.

  ## Options

    * `:actor` — Ash actor for loading the Filing + FilingRaw.
      Defaults to `LongOrShort.Accounts.SystemActor.new()` since
      extraction is a system-driven background concern.
    * `:provider` — override the AI provider for this call only.
      Useful in tests; otherwise the default `:ai_provider` config
      applies.
  """
  @spec extract(Filing.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def extract(%Filing{} = filing, opts \\ []) do
    actor = Keyword.get(opts, :actor, SystemActor.new())

    with {:ok, filing} <- ensure_loaded(filing, actor),
         {:ok, raw_text} <- raw_text(filing),
         {:ok, sections} <-
           SectionFilter.filter(raw_text, filing.filing_type,
             filing_subtype: filing.filing_subtype,
             max_section_chars: @max_section_chars
           ),
         :ok <- check_non_empty(sections),
         tier = Router.tier_for(filing.filing_type, filing.filing_subtype),
         provider = resolve_provider(opts),
         model = Router.model_for_tier(tier, provider),
         messages = Prompts.FilingExtraction.build(filing, sections),
         tools = [Tools.FilingExtraction.spec()],
         {:ok, response} <- AI.call(messages, tools, provider: provider, model: model),
         {:ok, tool_input} <- extract_tool_call(response),
         {:ok, validated} <- validate_extraction(tool_input) do
      {:ok,
       %{
         filing_id: filing.id,
         extraction: validated,
         provenance: %{
           model: model,
           tier: tier,
           provider: provider,
           usage: response.usage
         }
       }}
    end
  end

  # ── Loading + raw text access ──────────────────────────────────

  defp ensure_loaded(filing, actor) do
    case Filings.get_filing(filing.id, load: [:ticker, :filing_raw], actor: actor) do
      {:ok, loaded} -> {:ok, loaded}
      {:error, reason} -> {:error, {:load_failed, reason}}
    end
  end

  defp raw_text(%Filing{filing_raw: %{raw_text: text}}) when is_binary(text), do: {:ok, text}
  defp raw_text(%Filing{id: id}), do: {:error, {:filing_raw_missing, id}}

  defp check_non_empty([]), do: {:error, :no_relevant_content}
  defp check_non_empty(_), do: :ok

  defp resolve_provider(opts) do
    Keyword.get(opts, :provider) ||
      Application.fetch_env!(:long_or_short, :ai_provider)
  end

  # ── Tool call extraction ───────────────────────────────────────

  defp extract_tool_call(%{tool_calls: [%{name: "record_filing_extraction", input: input} | _]}),
    do: {:ok, input}

  defp extract_tool_call(_response), do: {:error, :no_tool_call}

  # ── Validation ─────────────────────────────────────────────────

  defp validate_extraction(input) when is_map(input) do
    with {:ok, dilution_type} <- validate_enum(:dilution_type, input, @dilution_type_atoms),
         {:ok, pricing_method} <- validate_enum(:pricing_method, input, @pricing_method_atoms) do
      validated =
        input
        |> normalize_keys()
        |> Map.put(:dilution_type, dilution_type)
        |> Map.put(:pricing_method, pricing_method)

      {:ok, validated}
    end
  end

  defp validate_enum(field, input, allowed_atoms) do
    case fetch_field(input, field) do
      :error ->
        {:error, {:missing_required, field}}

      {:ok, value} when is_binary(value) ->
        if value in Enum.map(allowed_atoms, &Atom.to_string/1) do
          # Safe: `value` was just validated against a closed compile-
          # time list, so `to_atom` cannot inflate the atom table.
          {:ok, String.to_atom(value)}
        else
          {:error, {:invalid_enum, field, value}}
        end

      {:ok, value} ->
        {:error, {:invalid_enum, field, value}}
    end
  end

  defp fetch_field(input, field) do
    case Map.fetch(input, field) do
      {:ok, _} = ok -> ok
      :error -> Map.fetch(input, Atom.to_string(field))
    end
  end

  # Tool-use responses arrive with string keys; downstream code prefers
  # atoms for known fields. Convert known keys; leave unknowns as-is so
  # the schema can grow without breaking validation.
  defp normalize_keys(input) do
    Enum.into(input, %{}, fn
      {k, v} when is_binary(k) ->
        case to_known_atom(k) do
          {:ok, atom} -> {atom, v}
          :error -> {k, v}
        end

      {k, v} ->
        {k, v}
    end)
  end

  @known_string_keys ~w(
    dilution_type deal_size_usd share_count pricing_method pricing_discount_pct
    warrant_strike warrant_term_years atm_remaining_shares
    atm_total_authorized_shares shelf_total_authorized_usd shelf_remaining_usd
    convertible_conversion_price has_anti_dilution_clause
    has_death_spiral_convertible is_reverse_split_proxy reverse_split_ratio
    summary
  )

  defp to_known_atom(key) when key in @known_string_keys, do: {:ok, String.to_atom(key)}
  defp to_known_atom(_), do: :error
end
