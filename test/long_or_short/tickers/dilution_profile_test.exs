defmodule LongOrShort.Tickers.DilutionProfileTest do
  @moduledoc """
  Tests for `LongOrShort.Tickers.DilutionProfile` exercised through
  the public surface `LongOrShort.Tickers.get_dilution_profile/1,2`
  — LON-116, Stage 4.

  Covers the output shape contract, window-based aggregation
  exclusion, `data_completeness` grading, `overall_severity` /
  reason selection, and the `AtmLifecycle` integration that
  populates `active_atm` end-to-end.
  """

  use LongOrShort.DataCase, async: true

  import LongOrShort.FilingsFixtures
  import LongOrShort.TickersFixtures

  alias LongOrShort.Tickers

  # Reference clock. Filings are placed relative to this so the
  # window cutoff stays deterministic regardless of suite time.
  @as_of ~U[2026-05-01 00:00:00.000000Z]

  describe "get_dilution_profile/2 — shape contract" do
    test "returns every top-level key with sensible defaults when ticker has no data" do
      ticker = build_ticker()

      profile = Tickers.get_dilution_profile(ticker.id, as_of: @as_of)

      assert profile.ticker_id == ticker.id
      assert profile.overall_severity == :none
      assert profile.overall_severity_reason == nil
      assert profile.active_atm == nil
      assert profile.pending_s1 == nil
      assert profile.warrant_overhang == nil
      assert profile.recent_reverse_split == nil
      assert profile.insider_selling_post_filing == false
      assert profile.flags == []
      assert profile.last_filing_at == nil
      assert profile.data_completeness == :insufficient
    end
  end

  describe "get_dilution_profile/2 — data_completeness" do
    test ":insufficient when no in-window FilingAnalysis exists" do
      ticker = build_ticker()

      # Out-of-window filing should not count toward completeness.
      old =
        build_filing_for_ticker(ticker, %{
          filing_type: :s1,
          filed_at: ~U[2025-10-01 00:00:00.000000Z]
        })

      build_filing_analysis(old, %{dilution_type: :s1_offering})

      assert %{data_completeness: :insufficient} =
               Tickers.get_dilution_profile(ticker.id, as_of: @as_of)
    end

    test ":partial when window data exists but no active ATM resolved" do
      ticker = build_ticker()

      s1 =
        build_filing_for_ticker(ticker, %{
          filing_type: :s1,
          filed_at: ~U[2026-04-01 00:00:00.000000Z]
        })

      build_filing_analysis(s1, %{
        dilution_type: :s1_offering,
        deal_size_usd: Decimal.new("25000000")
      })

      assert %{data_completeness: :partial} =
               Tickers.get_dilution_profile(ticker.id, as_of: @as_of)
    end

    test ":high when both an active ATM and any in-window analysis exist" do
      ticker = build_ticker()

      s3 =
        build_filing_for_ticker(ticker, %{
          filing_type: :s3,
          filed_at: ~U[2026-03-01 00:00:00.000000Z]
        })

      build_filing_analysis(s3, %{
        dilution_type: :atm,
        atm_total_authorized_shares: 10_000_000
      })

      assert %{data_completeness: :high, active_atm: %{remaining_shares: 10_000_000}} =
               Tickers.get_dilution_profile(ticker.id, as_of: @as_of)
    end
  end

  describe "get_dilution_profile/2 — window-based aggregation" do
    test "excludes filings older than :dilution_profile_window_days" do
      ticker = build_ticker()

      # Stale S-1 (~210 days before @as_of, outside default 180d window)
      old_s1 =
        build_filing_for_ticker(ticker, %{
          filing_type: :s1,
          filed_at: ~U[2025-10-01 00:00:00.000000Z]
        })

      build_filing_analysis(old_s1, %{
        dilution_type: :s1_offering,
        deal_size_usd: Decimal.new("999999999")
      })

      profile = Tickers.get_dilution_profile(ticker.id, as_of: @as_of)

      # The stale S-1 must not surface as pending_s1.
      assert profile.pending_s1 == nil
      # And the only filing was stale, so the profile is "no data".
      assert profile.data_completeness == :insufficient
    end

    test "pending_s1 picks the most recent S-1/S-1A within the window" do
      ticker = build_ticker()

      older =
        build_filing_for_ticker(ticker, %{
          filing_type: :s1,
          filed_at: ~U[2026-02-15 00:00:00.000000Z]
        })

      build_filing_analysis(older, %{
        dilution_type: :s1_offering,
        deal_size_usd: Decimal.new("10000000")
      })

      newer_filed_at = ~U[2026-04-01 00:00:00.000000Z]

      newer =
        build_filing_for_ticker(ticker, %{
          filing_type: :s1a,
          filed_at: newer_filed_at
        })

      build_filing_analysis(newer, %{
        dilution_type: :s1_offering,
        deal_size_usd: Decimal.new("25000000")
      })

      profile = Tickers.get_dilution_profile(ticker.id, as_of: @as_of)

      assert profile.pending_s1.filed_at == newer_filed_at
      assert Decimal.equal?(profile.pending_s1.deal_size_usd, Decimal.new("25000000"))
      assert profile.pending_s1.source_filing_id == newer.id
    end

    test "warrant_overhang sums share counts and averages strikes" do
      ticker = build_ticker()

      w1 =
        build_filing_for_ticker(ticker, %{
          filing_type: :s1,
          filed_at: ~U[2026-03-01 00:00:00.000000Z]
        })

      build_filing_analysis(w1, %{
        dilution_type: :warrant_exercise,
        share_count: 5_000_000,
        warrant_strike: Decimal.new("1.00")
      })

      w2 =
        build_filing_for_ticker(ticker, %{
          filing_type: :s1a,
          filed_at: ~U[2026-04-01 00:00:00.000000Z]
        })

      build_filing_analysis(w2, %{
        dilution_type: :warrant_exercise,
        share_count: 3_000_000,
        warrant_strike: Decimal.new("2.00")
      })

      profile = Tickers.get_dilution_profile(ticker.id, as_of: @as_of)

      assert profile.warrant_overhang.exercisable_shares == 8_000_000
      assert Decimal.equal?(profile.warrant_overhang.avg_strike, Decimal.new("1.5"))
      assert Enum.sort(profile.warrant_overhang.source_filing_ids) == Enum.sort([w1.id, w2.id])
    end

    test "recent_reverse_split picks the most recent within window" do
      ticker = build_ticker()

      older =
        build_filing_for_ticker(ticker, %{
          filing_type: :def14a,
          filed_at: ~U[2026-02-01 00:00:00.000000Z]
        })

      build_filing_analysis(older, %{
        dilution_type: :reverse_split,
        is_reverse_split_proxy: true,
        reverse_split_ratio: "1:5"
      })

      newer_filed_at = ~U[2026-04-15 00:00:00.000000Z]

      newer =
        build_filing_for_ticker(ticker, %{
          filing_type: :_8k,
          filed_at: newer_filed_at
        })

      build_filing_analysis(newer, %{
        dilution_type: :reverse_split,
        reverse_split_ratio: "1:10"
      })

      profile = Tickers.get_dilution_profile(ticker.id, as_of: @as_of)

      assert profile.recent_reverse_split.ratio == "1:10"
      assert profile.recent_reverse_split.executed_at == newer_filed_at
      assert profile.recent_reverse_split.source_filing_id == newer.id
    end
  end

  describe "get_dilution_profile/2 — overall_severity" do
    test "picks the highest severity among contributing rows" do
      ticker = build_ticker()

      low =
        build_filing_for_ticker(ticker, %{
          filing_type: :s1,
          filed_at: ~U[2026-03-01 00:00:00.000000Z]
        })

      build_filing_analysis(low, %{
        dilution_severity: :low,
        severity_reason: "low-impact S-1"
      })

      high =
        build_filing_for_ticker(ticker, %{
          filing_type: :_8k,
          filed_at: ~U[2026-04-01 00:00:00.000000Z]
        })

      build_filing_analysis(high, %{
        dilution_severity: :high,
        severity_reason: "ATM > 50% of float"
      })

      medium =
        build_filing_for_ticker(ticker, %{
          filing_type: :def14a,
          filed_at: ~U[2026-04-15 00:00:00.000000Z]
        })

      build_filing_analysis(medium, %{
        dilution_severity: :medium,
        severity_reason: "warrant overhang"
      })

      profile = Tickers.get_dilution_profile(ticker.id, as_of: @as_of)

      assert profile.overall_severity == :high
      assert profile.overall_severity_reason == "ATM > 50% of float"
    end

    test "ignores rows with severity :none" do
      ticker = build_ticker()

      none_row =
        build_filing_for_ticker(ticker, %{
          filing_type: :s1,
          filed_at: ~U[2026-04-01 00:00:00.000000Z]
        })

      build_filing_analysis(none_row, %{
        dilution_severity: :none,
        severity_reason: "should never surface"
      })

      profile = Tickers.get_dilution_profile(ticker.id, as_of: @as_of)

      assert profile.overall_severity == :none
      assert profile.overall_severity_reason == nil
    end

    test "overall_severity_reason matches the row that contributed the max severity" do
      ticker = build_ticker()

      # Two rows at :high, both within window. The :high row created
      # second has a strictly later `analyzed_at` than the first, so
      # the tie-break inside max_by (by analyzed_at desc) should
      # surface the second row's reason.
      first =
        build_filing_for_ticker(ticker, %{
          filing_type: :_8k,
          filed_at: ~U[2026-03-01 00:00:00.000000Z]
        })

      build_filing_analysis(first, %{
        dilution_severity: :high,
        severity_reason: "first high reason"
      })

      second =
        build_filing_for_ticker(ticker, %{
          filing_type: :_8k,
          filed_at: ~U[2026-04-01 00:00:00.000000Z]
        })

      build_filing_analysis(second, %{
        dilution_severity: :high,
        severity_reason: "second high reason"
      })

      profile = Tickers.get_dilution_profile(ticker.id, as_of: @as_of)

      assert profile.overall_severity == :high
      assert profile.overall_severity_reason == "second high reason"
    end
  end

  describe "get_dilution_profile/2 — ATM lifecycle integration" do
    test "populates active_atm from the S-3 → 424B5 chain end-to-end" do
      ticker = build_ticker()

      s3 =
        build_filing_for_ticker(ticker, %{
          filing_type: :s3,
          filed_at: ~U[2026-02-15 10:00:00.000000Z]
        })

      build_filing_analysis(s3, %{
        dilution_type: :atm,
        atm_total_authorized_shares: 20_000_000,
        pricing_method: :market_minus_pct,
        pricing_discount_pct: Decimal.new("5.0")
      })

      for {date, count} <- [
            {~U[2026-03-01 00:00:00.000000Z], 3_000_000},
            {~U[2026-03-15 00:00:00.000000Z], 2_500_000},
            {~U[2026-04-01 00:00:00.000000Z], 2_500_000}
          ] do
        f = build_filing_for_ticker(ticker, %{filing_type: :_424b5, filed_at: date})
        build_filing_analysis(f, %{dilution_type: :atm, share_count: count})
      end

      profile = Tickers.get_dilution_profile(ticker.id, as_of: @as_of)

      assert profile.active_atm.remaining_shares == 12_000_000
      assert profile.active_atm.used_to_date == 8_000_000
      assert profile.active_atm.pricing_method == :market_minus_pct
      assert profile.data_completeness == :high
    end
  end

  describe "get_dilution_profile/2 — last_filing_at" do
    test "returns the max filed_at across in-window analyses" do
      ticker = build_ticker()

      earlier =
        build_filing_for_ticker(ticker, %{
          filing_type: :s1,
          filed_at: ~U[2026-02-01 00:00:00.000000Z]
        })

      build_filing_analysis(earlier, %{dilution_type: :s1_offering})

      latest_filed_at = ~U[2026-04-15 00:00:00.000000Z]

      latest =
        build_filing_for_ticker(ticker, %{
          filing_type: :def14a,
          filed_at: latest_filed_at
        })

      build_filing_analysis(latest, %{dilution_type: :reverse_split})

      profile = Tickers.get_dilution_profile(ticker.id, as_of: @as_of)

      assert profile.last_filing_at == latest_filed_at
    end
  end
end
