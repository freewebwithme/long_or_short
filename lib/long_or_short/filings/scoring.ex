defmodule LongOrShort.Filings.Scoring do
  @moduledoc """
  Orchestrator that combines validation and severity rules to produce
  a final dilution-severity verdict for a filing extraction (LON-114).

  Sits on top of `LongOrShort.Filings.Validation` and
  `LongOrShort.Filings.SeverityRules`. Stage 3c (LON-115) will call
  this immediately after `Filings.Extractor.extract/2` and before
  persisting the FilingAnalysis row.

  ## Pipeline

      extraction (from Extractor) + ticker_context
        → Validation.validate
            failure → return :rejected quality + rejection details
            success → run all SeverityRules
                          empty → try rule_default_low fallback
                                       fires → :low result
                                       still empty → :none result
                          non-empty → highest severity wins, all
                                      matched rules listed for audit

  ## Result shape

      %{
        severity:           :critical | :high | :medium | :low | :none,
        matched_rules:      [rule_name :: atom()],
        reason:             String.t() | nil,
        extraction_quality: :high | :medium | :rejected,
        rejection:          %{check: atom(), context: map()} | nil
      }

  Stage 3c will persist all these fields onto the `FilingAnalysis`
  resource. Keeping `rejection` as an explicit `nil`-or-map field
  (rather than absent) means callers always get the same key set
  back regardless of validation outcome.

  ## Why a map, not the tuple from the LON-114 spec

  The LON-114 spec described the return as a tuple
  `{severity, [rule_names], reason_string}`. We return a map instead
  for two reasons:

    1. Stage 3c (LON-115) will need to fan multiple fields onto a
       single FilingAnalysis row — `extraction_quality`,
       `matched_rules`, `severity`, `reason`, plus any
       rejection details. Map keys map cleanly to row fields.
    2. Future additions (e.g. confidence, baseline-adjusted severity
       per LON-121) extend the map without breaking existing callers.
  """

  alias LongOrShort.Filings.{SeverityRules, Validation}

  @typedoc "Final verdict returned by `score/2`."
  @type result :: %{
          severity: SeverityRules.severity() | :none,
          matched_rules: [atom()],
          reason: String.t() | nil,
          extraction_quality: :high | :medium | :rejected,
          rejection: %{check: atom(), context: map()} | nil
        }

  @doc """
  Run validation + severity rules against an extraction and return the
  final verdict.

  `ticker_context` must contain at minimum `:filing` and `:ticker`
  (those are required by the rules). Optional pre-computed signals
  (`:rvol`, `:recent_catalyst?`, `:has_active_shelf?`,
  `:has_active_atm?`, `:now`) may be added — see
  `LongOrShort.Filings.SeverityRules` moduledoc for the full context shape.
  """
  @spec score(map(), SeverityRules.ticker_context()) :: result()
  def score(extraction, ticker_context) when is_map(extraction) and is_map(ticker_context) do
    %{filing: filing, ticker: ticker} = ticker_context

    case Validation.validate(extraction, filing, ticker) do
      :ok ->
        run_rules(extraction, ticker_context)

      {:error, {:rejected, check, ctx}} ->
        rejection_result(check, ctx)
    end
  end

  # ── Rule dispatch ──────────────────────────────────────────────

  defp run_rules(extraction, ticker_context) do
    matches =
      SeverityRules.all_rules()
      |> Enum.map(fn rule_name ->
        apply(SeverityRules, rule_name, [extraction, ticker_context])
      end)
      |> Enum.reject(&is_nil/1)

    case matches do
      [] ->
        # Nothing in the standard rule set fired. Try the default-low
        # fallback — fires only when extraction shows some dilution_type
        # but no specific rule matched.
        case SeverityRules.rule_default_low(extraction, ticker_context) do
          nil -> empty_result()
          fallback -> result_from_matches([fallback])
        end

      _ ->
        result_from_matches(matches)
    end
  end

  defp result_from_matches(matches) do
    {highest_severity, _, highest_reason} = pick_highest(matches)

    %{
      severity: highest_severity,
      matched_rules: Enum.map(matches, fn {_, name, _} -> name end),
      reason: highest_reason,
      extraction_quality: :high,
      rejection: nil
    }
  end

  # Highest severity = lowest index in the ordered severity_levels list
  # (severity_levels/0 returns [:critical, :high, :medium, :low]).
  defp pick_highest(matches) do
    index = severity_index()
    Enum.min_by(matches, fn {sev, _, _} -> Map.fetch!(index, sev) end)
  end

  defp severity_index do
    SeverityRules.severity_levels()
    |> Enum.with_index()
    |> Map.new()
  end

  # ── Result constructors ────────────────────────────────────────

  defp empty_result do
    %{
      severity: :none,
      matched_rules: [],
      reason: nil,
      extraction_quality: :high,
      rejection: nil
    }
  end

  defp rejection_result(check, context) do
    %{
      severity: :none,
      matched_rules: [],
      reason: "Rejected by validation: #{check}",
      extraction_quality: :rejected,
      rejection: %{check: check, context: context}
    }
  end
end
