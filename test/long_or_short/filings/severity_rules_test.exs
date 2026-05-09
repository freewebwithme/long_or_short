defmodule LongOrShort.Filings.SeverityRulesTest do
  @moduledoc """
  Per-rule tests for `LongOrShort.Filings.SeverityRules`.

  Each of the 9 standard rules + `rule_default_low` has positive,
  negative, and boundary cases. Inline struct fixtures keep tests
  fast and DB-free.
  """

  use ExUnit.Case, async: true

  alias LongOrShort.Filings.{Filing, SeverityRules}
  alias LongOrShort.Tickers.Ticker

  # ── Inline struct + context helpers ────────────────────────────

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

  # ── Module-level metadata ──────────────────────────────────────

  describe "all_rules/0 + severity_levels/0" do
    test "all_rules returns 9 standard rule names" do
      rules = SeverityRules.all_rules()
      assert length(rules) == 9
      assert :rule_default_low not in rules
    end

    test "all listed rules are exported as 2-arity functions" do
      for rule <- SeverityRules.all_rules() do
        assert function_exported?(SeverityRules, rule, 2),
               "rule #{rule} listed in all_rules/0 but not exported"
      end
    end

    test "severity_levels in descending severity order" do
      assert SeverityRules.severity_levels() == [:critical, :high, :medium, :low]
    end
  end

  # ── Rule 1: rule_atm_majority_of_float ─────────────────────────

  describe "rule_atm_majority_of_float" do
    test "fires :critical when ATM remaining > 50% of float" do
      extraction = %{dilution_type: :atm, atm_remaining_shares: 6_000_000}
      ctx = ctx(%{ticker: ticker(%{float_shares: 10_000_000})})

      assert {:critical, :rule_atm_majority_of_float, reason} =
               SeverityRules.rule_atm_majority_of_float(extraction, ctx)

      assert reason =~ "60.0%"
    end

    test "does not fire below 50%" do
      extraction = %{dilution_type: :atm, atm_remaining_shares: 4_000_000}
      ctx = ctx(%{ticker: ticker(%{float_shares: 10_000_000})})

      assert nil ==
               SeverityRules.rule_atm_majority_of_float(extraction, ctx)
    end

    test "boundary — exactly 50% does not fire (strict >)" do
      extraction = %{dilution_type: :atm, atm_remaining_shares: 5_000_000}
      ctx = ctx(%{ticker: ticker(%{float_shares: 10_000_000})})

      assert nil ==
               SeverityRules.rule_atm_majority_of_float(extraction, ctx)
    end

    test "does not fire when dilution_type isn't :atm" do
      extraction = %{dilution_type: :pipe, atm_remaining_shares: 999_000_000}
      assert nil == SeverityRules.rule_atm_majority_of_float(extraction, ctx())
    end
  end

  # ── Rule 2: rule_atm_significant_overhang ─────────────────────

  describe "rule_atm_significant_overhang" do
    test "fires :high in 20–50% band" do
      extraction = %{dilution_type: :atm, atm_remaining_shares: 3_000_000}
      ctx = ctx(%{ticker: ticker(%{float_shares: 10_000_000})})

      assert {:high, :rule_atm_significant_overhang, reason} =
               SeverityRules.rule_atm_significant_overhang(extraction, ctx)

      assert reason =~ "30.0%"
    end

    test "does not fire below 20%" do
      extraction = %{dilution_type: :atm, atm_remaining_shares: 1_500_000}
      ctx = ctx(%{ticker: ticker(%{float_shares: 10_000_000})})

      assert nil == SeverityRules.rule_atm_significant_overhang(extraction, ctx)
    end

    test "boundary — at 50% inclusive (rule fires up to and including 50%)" do
      extraction = %{dilution_type: :atm, atm_remaining_shares: 5_000_000}
      ctx = ctx(%{ticker: ticker(%{float_shares: 10_000_000})})

      assert {:high, _, _} = SeverityRules.rule_atm_significant_overhang(extraction, ctx)
    end

    test "boundary — at 20% does not fire (strict >)" do
      extraction = %{dilution_type: :atm, atm_remaining_shares: 2_000_000}
      ctx = ctx(%{ticker: ticker(%{float_shares: 10_000_000})})

      assert nil == SeverityRules.rule_atm_significant_overhang(extraction, ctx)
    end
  end

  # ── Rule 3: rule_atm_active_during_spike ──────────────────────

  describe "rule_atm_active_during_spike" do
    test "fires :high when ATM + RVOL > 3" do
      extraction = %{dilution_type: :atm}

      assert {:high, :rule_atm_active_during_spike, reason} =
               SeverityRules.rule_atm_active_during_spike(extraction, ctx(%{rvol: 4.5}))

      assert reason =~ "RVOL 4.5"
    end

    test "fires :high when ATM + recent_catalyst?: true" do
      extraction = %{dilution_type: :atm}

      assert {:high, :rule_atm_active_during_spike, reason} =
               SeverityRules.rule_atm_active_during_spike(
                 extraction,
                 ctx(%{recent_catalyst?: true})
               )

      assert reason =~ "catalyst"
    end

    test "boundary — RVOL exactly 3.0 does not fire (strict >)" do
      extraction = %{dilution_type: :atm}
      assert nil == SeverityRules.rule_atm_active_during_spike(extraction, ctx(%{rvol: 3.0}))
    end

    test "does not fire when context lacks both RVOL and catalyst flag" do
      extraction = %{dilution_type: :atm}
      assert nil == SeverityRules.rule_atm_active_during_spike(extraction, ctx())
    end

    test "does not fire when dilution_type isn't :atm" do
      assert nil ==
               SeverityRules.rule_atm_active_during_spike(
                 %{dilution_type: :pipe},
                 ctx(%{rvol: 5.0})
               )
    end
  end

  # ── Rule 4: rule_recent_s1_filing ─────────────────────────────

  describe "rule_recent_s1_filing" do
    test "fires :high for S-1 within 14 days" do
      ctx = ctx(%{filing: filing(%{filing_type: :s1, filed_at: days_before_now(5)})})

      assert {:high, :rule_recent_s1_filing, reason} =
               SeverityRules.rule_recent_s1_filing(%{}, ctx)

      assert reason =~ "S-1"
      assert reason =~ "5 days ago"
    end

    test "fires :high for S-1/A within 14 days" do
      ctx = ctx(%{filing: filing(%{filing_type: :s1a, filed_at: days_before_now(10)})})

      assert {:high, :rule_recent_s1_filing, _} =
               SeverityRules.rule_recent_s1_filing(%{}, ctx)
    end

    test "boundary — exactly 14 days fires" do
      ctx = ctx(%{filing: filing(%{filing_type: :s1, filed_at: days_before_now(14)})})
      assert {:high, _, _} = SeverityRules.rule_recent_s1_filing(%{}, ctx)
    end

    test "does not fire after 14 days" do
      ctx = ctx(%{filing: filing(%{filing_type: :s1, filed_at: days_before_now(15)})})
      assert nil == SeverityRules.rule_recent_s1_filing(%{}, ctx)
    end

    test "does not fire for non-S-1 filing types" do
      ctx = ctx(%{filing: filing(%{filing_type: :_8k, filed_at: days_before_now(1)})})
      assert nil == SeverityRules.rule_recent_s1_filing(%{}, ctx)
    end
  end

  # ── Rule 5: rule_active_shelf_with_atm ────────────────────────

  describe "rule_active_shelf_with_atm" do
    test "fires :high when both flags true" do
      assert {:high, :rule_active_shelf_with_atm, _} =
               SeverityRules.rule_active_shelf_with_atm(
                 %{},
                 ctx(%{has_active_shelf?: true, has_active_atm?: true})
               )
    end

    test "does not fire when only shelf flag is true" do
      assert nil ==
               SeverityRules.rule_active_shelf_with_atm(
                 %{},
                 ctx(%{has_active_shelf?: true, has_active_atm?: false})
               )
    end

    test "does not fire when only ATM flag is true" do
      assert nil ==
               SeverityRules.rule_active_shelf_with_atm(
                 %{},
                 ctx(%{has_active_shelf?: false, has_active_atm?: true})
               )
    end

    test "does not fire when both flags missing" do
      assert nil == SeverityRules.rule_active_shelf_with_atm(%{}, ctx())
    end
  end

  # ── Rule 6: rule_warrant_overhang_in_money ────────────────────

  describe "rule_warrant_overhang_in_money" do
    # Default ticker: float 10M, last_price $5

    test "fires :medium when warrant overhang > 30% of float and strike < last_price" do
      extraction = %{warrant_strike: 2.50, share_count: 4_000_000}

      assert {:medium, :rule_warrant_overhang_in_money, reason} =
               SeverityRules.rule_warrant_overhang_in_money(extraction, ctx())

      assert reason =~ "40.0% of float"
      assert reason =~ "2.50"
    end

    test "boundary — at exactly 30% does not fire (strict >)" do
      extraction = %{warrant_strike: 2.50, share_count: 3_000_000}
      assert nil == SeverityRules.rule_warrant_overhang_in_money(extraction, ctx())
    end

    test "does not fire when strike >= last_price (out of money)" do
      extraction = %{warrant_strike: 6.00, share_count: 5_000_000}
      assert nil == SeverityRules.rule_warrant_overhang_in_money(extraction, ctx())
    end

    test "does not fire when no warrant_strike" do
      extraction = %{warrant_strike: nil, share_count: 5_000_000}
      assert nil == SeverityRules.rule_warrant_overhang_in_money(extraction, ctx())
    end

    test "does not fire when last_price missing on ticker" do
      extraction = %{warrant_strike: 1.0, share_count: 5_000_000}
      ctx = ctx(%{ticker: ticker(%{last_price: nil})})
      assert nil == SeverityRules.rule_warrant_overhang_in_money(extraction, ctx)
    end
  end

  # ── Rule 7: rule_recent_reverse_split ─────────────────────────

  describe "rule_recent_reverse_split" do
    test "fires :high when dilution_type is :reverse_split within 90 days" do
      ctx = ctx(%{filing: filing(%{filed_at: days_before_now(45)})})

      assert {:high, :rule_recent_reverse_split, reason} =
               SeverityRules.rule_recent_reverse_split(%{dilution_type: :reverse_split}, ctx)

      assert reason =~ "45 days ago"
    end

    test "boundary — exactly 90 days fires" do
      ctx = ctx(%{filing: filing(%{filed_at: days_before_now(90)})})

      assert {:high, _, _} =
               SeverityRules.rule_recent_reverse_split(%{dilution_type: :reverse_split}, ctx)
    end

    test "does not fire after 90 days" do
      ctx = ctx(%{filing: filing(%{filed_at: days_before_now(91)})})

      assert nil ==
               SeverityRules.rule_recent_reverse_split(%{dilution_type: :reverse_split}, ctx)
    end

    test "does not fire for non-reverse-split dilution types" do
      ctx = ctx(%{filing: filing(%{filed_at: days_before_now(5)})})
      assert nil == SeverityRules.rule_recent_reverse_split(%{dilution_type: :pipe}, ctx)
    end
  end

  # ── Rule 8: rule_recent_pipe ──────────────────────────────────

  describe "rule_recent_pipe" do
    test "fires :critical when PIPE within 7 days" do
      ctx = ctx(%{filing: filing(%{filed_at: days_before_now(3)})})

      assert {:critical, :rule_recent_pipe, reason} =
               SeverityRules.rule_recent_pipe(%{dilution_type: :pipe}, ctx)

      assert reason =~ "3 days"
    end

    test "boundary — exactly 7 days fires" do
      ctx = ctx(%{filing: filing(%{filed_at: days_before_now(7)})})
      assert {:critical, _, _} = SeverityRules.rule_recent_pipe(%{dilution_type: :pipe}, ctx)
    end

    test "does not fire after 7 days" do
      ctx = ctx(%{filing: filing(%{filed_at: days_before_now(8)})})
      assert nil == SeverityRules.rule_recent_pipe(%{dilution_type: :pipe}, ctx)
    end

    test "does not fire for non-PIPE dilution types" do
      ctx = ctx(%{filing: filing(%{filed_at: days_before_now(1)})})
      assert nil == SeverityRules.rule_recent_pipe(%{dilution_type: :atm}, ctx)
    end
  end

  # ── Rule 9: rule_death_spiral_convertible ─────────────────────

  describe "rule_death_spiral_convertible" do
    test "fires :critical when extraction flag is true" do
      assert {:critical, :rule_death_spiral_convertible, reason} =
               SeverityRules.rule_death_spiral_convertible(
                 %{has_death_spiral_convertible: true},
                 ctx()
               )

      assert reason =~ ~r/death-spiral/i
    end

    test "does not fire when flag is false" do
      assert nil ==
               SeverityRules.rule_death_spiral_convertible(
                 %{has_death_spiral_convertible: false},
                 ctx()
               )
    end

    test "does not fire when flag is missing" do
      assert nil == SeverityRules.rule_death_spiral_convertible(%{}, ctx())
    end
  end

  # ── rule_default_low (catch-all fallback) ─────────────────────

  describe "rule_default_low" do
    test "fires :low for any non-:none dilution_type" do
      for type <- [:atm, :s1_offering, :pipe, :warrant_exercise] do
        assert {:low, :rule_default_low, reason} =
                 SeverityRules.rule_default_low(%{dilution_type: type}, ctx()),
               "expected fallback to fire for type #{type}"

        assert is_binary(reason)
      end
    end

    test "does not fire for :none" do
      assert nil == SeverityRules.rule_default_low(%{dilution_type: :none}, ctx())
    end

    test "does not fire when dilution_type is nil" do
      assert nil == SeverityRules.rule_default_low(%{dilution_type: nil}, ctx())
    end

    test "does not fire when extraction has no dilution_type key" do
      assert nil == SeverityRules.rule_default_low(%{}, ctx())
    end
  end
end
