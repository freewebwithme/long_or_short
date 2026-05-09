defmodule LongOrShort.Filings.ScoringTest do
  @moduledoc """
  Integration tests for `LongOrShort.Filings.Scoring`.

  Exercises the orchestration: validation pass/fail, single rule
  firing, multiple rules firing (highest wins), no rules firing
  (default-low fallback or :none), and result-map shape.
  """

  use ExUnit.Case, async: true

  alias LongOrShort.Filings.{Filing, Scoring}
  alias LongOrShort.Tickers.Ticker

  @fixed_now ~U[2026-05-09 00:00:00Z]

  defp filing(attrs \\ %{}) do
    defaults = %{
      id: "00000000-0000-0000-0000-000000000001",
      source: :sec_edgar,
      filing_type: :_8k,
      filing_subtype: nil,
      external_id: "ext-1",
      filer_cik: "0001234567",
      filed_at: @fixed_now,
      url: nil,
      ticker_id: "00000000-0000-0000-0000-000000000002"
    }

    struct(Filing, Map.merge(defaults, attrs))
  end

  defp ticker(attrs \\ %{}) do
    defaults = %{
      id: "00000000-0000-0000-0000-000000000002",
      symbol: "TEST",
      cik: "0001234567",
      last_price: Decimal.new("5.00"),
      float_shares: 10_000_000,
      shares_outstanding: 20_000_000,
      avg_volume_30d: 500_000,
      is_active: true
    }

    struct(Ticker, Map.merge(defaults, attrs))
  end

  defp ctx(extras \\ %{}) do
    Map.merge(%{filing: filing(), ticker: ticker(), now: @fixed_now}, extras)
  end

  defp days_before_now(n), do: DateTime.add(@fixed_now, -n, :day)

  defp valid_extraction(overrides) do
    Map.merge(
      %{
        dilution_type: :pipe,
        share_count: 1_000_000,
        deal_size_usd: 5_000_000,
        pricing_method: :fixed,
        has_anti_dilution_clause: false,
        has_death_spiral_convertible: false,
        is_reverse_split_proxy: false
      },
      overrides
    )
  end

  # ── Validation rejection path ──────────────────────────────────

  describe "score/2 — validation rejected" do
    test "returns :rejected quality with rejection details" do
      bad = valid_extraction(%{share_count: -1})

      assert %{
               severity: :none,
               matched_rules: [],
               extraction_quality: :rejected,
               rejection: %{check: :share_count_positive, context: %{share_count: -1}}
             } = Scoring.score(bad, ctx())
    end

    test "no rules are evaluated when validation fails" do
      # Even though the PIPE-within-7-days rule would otherwise fire,
      # validation rejects upstream and matched_rules stays empty.
      bad = valid_extraction(%{share_count: -1, dilution_type: :pipe})
      ctx = ctx(%{filing: filing(%{filed_at: days_before_now(1)})})

      result = Scoring.score(bad, ctx)
      assert result.matched_rules == []
      assert result.severity == :none
    end
  end

  # ── No rule fires + fallback ───────────────────────────────────

  describe "score/2 — fallback path" do
    test "rule_default_low fires when extraction shows dilution but no rule matches" do
      # Generic warrant_exercise with no warrant_strike, no recent date,
      # no flags — no specific rule applies, so default-low kicks in.
      extraction = valid_extraction(%{dilution_type: :warrant_exercise})

      # Filing dated long ago so no time-windowed rule fires
      ctx = ctx(%{filing: filing(%{filed_at: days_before_now(365)})})

      assert %{
               severity: :low,
               matched_rules: [:rule_default_low],
               extraction_quality: :high,
               rejection: nil
             } = Scoring.score(extraction, ctx)
    end

    test "returns :none when extraction has dilution_type :none" do
      extraction = valid_extraction(%{dilution_type: :none})
      ctx = ctx(%{filing: filing(%{filed_at: days_before_now(365)})})

      assert %{
               severity: :none,
               matched_rules: [],
               reason: nil,
               extraction_quality: :high,
               rejection: nil
             } = Scoring.score(extraction, ctx)
    end
  end

  # ── Single rule fires ──────────────────────────────────────────

  describe "score/2 — single rule fires" do
    test "death-spiral convertible alone yields :critical" do
      extraction =
        valid_extraction(%{dilution_type: :convertible_conversion, has_death_spiral_convertible: true})

      result = Scoring.score(extraction, ctx())

      assert result.severity == :critical
      assert :rule_death_spiral_convertible in result.matched_rules
      assert result.reason =~ ~r/death-spiral/i
      assert result.extraction_quality == :high
    end

    test "recent S-1 alone yields :high" do
      extraction = valid_extraction(%{dilution_type: :s1_offering})

      ctx =
        ctx(%{
          filing: filing(%{filing_type: :s1, filed_at: days_before_now(3)})
        })

      result = Scoring.score(extraction, ctx)

      assert result.severity == :high
      assert :rule_recent_s1_filing in result.matched_rules
    end
  end

  # ── Multiple rules fire — highest wins ─────────────────────────

  describe "score/2 — multiple rules fire" do
    test "highest severity wins; matched_rules lists all that fired" do
      extraction =
        valid_extraction(%{
          dilution_type: :atm,
          atm_remaining_shares: 7_000_000,
          has_death_spiral_convertible: true
        })

      ctx = ctx(%{ticker: ticker(%{float_shares: 10_000_000}), rvol: 5.0})

      result = Scoring.score(extraction, ctx)

      # Three :critical-eligible rules can fire here:
      # - rule_atm_majority_of_float (70% of float)
      # - rule_death_spiral_convertible
      # plus :high rule_atm_active_during_spike (RVOL 5 > 3)
      assert result.severity == :critical

      assert :rule_atm_majority_of_float in result.matched_rules
      assert :rule_death_spiral_convertible in result.matched_rules
      assert :rule_atm_active_during_spike in result.matched_rules

      # Reason comes from one of the highest-severity rules
      assert result.reason != nil
      assert result.extraction_quality == :high
    end

    test "PIPE within 7d (:critical) outranks default-low" do
      # Extraction has dilution_type :pipe — rule_default_low would
      # fire if it were called, but the orchestrator only calls it
      # when no other rule fires. PIPE within 7d is :critical, so
      # default-low must NOT appear in matched_rules.
      extraction = valid_extraction(%{dilution_type: :pipe})
      ctx = ctx(%{filing: filing(%{filed_at: days_before_now(2)})})

      result = Scoring.score(extraction, ctx)

      assert result.severity == :critical
      assert :rule_recent_pipe in result.matched_rules
      assert :rule_default_low not in result.matched_rules
    end
  end

  # ── Result map shape ───────────────────────────────────────────

  describe "score/2 — result shape invariants" do
    test "all four core keys plus rejection are always present" do
      result = Scoring.score(valid_extraction(%{dilution_type: :none}), ctx())

      assert Map.has_key?(result, :severity)
      assert Map.has_key?(result, :matched_rules)
      assert Map.has_key?(result, :reason)
      assert Map.has_key?(result, :extraction_quality)
      assert Map.has_key?(result, :rejection)
    end

    test "matched_rules is always a list" do
      assert is_list(Scoring.score(valid_extraction(%{share_count: -1}), ctx()).matched_rules)
      assert is_list(Scoring.score(valid_extraction(%{dilution_type: :none}), ctx()).matched_rules)
    end

    test "rejection is nil on the happy path" do
      result = Scoring.score(valid_extraction(%{dilution_type: :pipe}), ctx())
      assert result.rejection == nil
    end
  end
end
