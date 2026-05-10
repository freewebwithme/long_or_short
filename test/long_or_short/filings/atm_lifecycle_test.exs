defmodule LongOrShort.Filings.AtmLifecycleTest do
  @moduledoc """
  Unit tests for `LongOrShort.Filings.AtmLifecycle` — LON-116, Stage 4.

  Synthetic S-3 → 424B5\\* chains exercise the resolver's lifecycle
  walk, dormancy cutoff, and orphan-detection paths.
  """

  use LongOrShort.DataCase, async: true

  import ExUnit.CaptureLog
  import LongOrShort.FilingsFixtures
  import LongOrShort.TickersFixtures

  alias LongOrShort.Filings.AtmLifecycle

  # Reference clock for all tests. Pinning `as_of` keeps the dormancy
  # boundary deterministic regardless of when the suite runs.
  @as_of ~U[2026-05-01 00:00:00.000000Z]

  describe "resolve/2 — no ATM data" do
    test "returns nil when the ticker has no FilingAnalysis rows" do
      ticker = build_ticker()
      assert AtmLifecycle.resolve(ticker.id, as_of: @as_of) == nil
    end

    test "returns nil when the ticker has only non-ATM dilution analyses" do
      ticker = build_ticker()
      filing = build_filing_for_ticker(ticker, %{filing_type: :s1})

      build_filing_analysis(filing, %{
        dilution_type: :s1_offering,
        deal_size_usd: Decimal.new("25000000")
      })

      assert AtmLifecycle.resolve(ticker.id, as_of: @as_of) == nil
    end
  end

  describe "resolve/2 — orphan 424B5" do
    test "returns nil and logs a warning when a 424B5 exists without a parent S-3" do
      ticker = build_ticker()

      filing =
        build_filing_for_ticker(ticker, %{
          filing_type: :_424b5,
          filed_at: ~U[2026-03-01 00:00:00.000000Z]
        })

      build_filing_analysis(filing, %{dilution_type: :atm, share_count: 500_000})

      log =
        capture_log(fn ->
          assert AtmLifecycle.resolve(ticker.id, as_of: @as_of) == nil
        end)

      assert log =~ "orphan 424B5"
    end
  end

  describe "resolve/2 — S-3 registration only" do
    test "returns active ATM with full capacity and no 424B5 timestamp" do
      ticker = build_ticker()
      registered_at = ~U[2026-02-15 10:00:00.000000Z]

      s3 = build_filing_for_ticker(ticker, %{filing_type: :s3, filed_at: registered_at})

      build_filing_analysis(s3, %{
        dilution_type: :atm,
        atm_total_authorized_shares: 20_000_000,
        pricing_method: :market_minus_pct,
        pricing_discount_pct: Decimal.new("5.0")
      })

      assert %{
               remaining_shares: 20_000_000,
               used_to_date: 0,
               registered_at: ^registered_at,
               last_424b_filed_at: nil,
               pricing_method: :market_minus_pct,
               source_filing_ids: [s3_id]
             } = AtmLifecycle.resolve(ticker.id, as_of: @as_of)

      assert s3_id == s3.id
    end
  end

  describe "resolve/2 — full S-3 → 424B5 chain" do
    test "decrements remaining_shares across the chain and tracks last_424b_filed_at" do
      ticker = build_ticker()

      s3 =
        build_filing_for_ticker(ticker, %{
          filing_type: :s3,
          filed_at: ~U[2026-02-15 10:00:00.000000Z]
        })

      build_filing_analysis(s3, %{
        dilution_type: :atm,
        atm_total_authorized_shares: 20_000_000,
        pricing_method: :vwap_based
      })

      supplement_1 =
        build_filing_for_ticker(ticker, %{
          filing_type: :_424b5,
          filed_at: ~U[2026-03-01 12:00:00.000000Z]
        })

      build_filing_analysis(supplement_1, %{dilution_type: :atm, share_count: 3_000_000})

      supplement_2 =
        build_filing_for_ticker(ticker, %{
          filing_type: :_424b5,
          filed_at: ~U[2026-03-15 12:00:00.000000Z]
        })

      build_filing_analysis(supplement_2, %{dilution_type: :atm, share_count: 2_500_000})

      last_supplement_filed_at = ~U[2026-04-01 12:00:00.000000Z]

      supplement_3 =
        build_filing_for_ticker(ticker, %{
          filing_type: :_424b5,
          filed_at: last_supplement_filed_at
        })

      build_filing_analysis(supplement_3, %{dilution_type: :atm, share_count: 2_500_000})

      result = AtmLifecycle.resolve(ticker.id, as_of: @as_of)

      assert result.remaining_shares == 12_000_000
      assert result.used_to_date == 8_000_000
      assert result.last_424b_filed_at == last_supplement_filed_at
      assert length(result.source_filing_ids) == 4
      assert s3.id in result.source_filing_ids

      for f <- [supplement_1, supplement_2, supplement_3] do
        assert f.id in result.source_filing_ids
      end
    end
  end

  describe "resolve/2 — exhausted" do
    test "returns nil when used_to_date matches authorized" do
      ticker = build_ticker()

      s3 =
        build_filing_for_ticker(ticker, %{
          filing_type: :s3,
          filed_at: ~U[2026-02-15 00:00:00.000000Z]
        })

      build_filing_analysis(s3, %{dilution_type: :atm, atm_total_authorized_shares: 10_000_000})

      supplement =
        build_filing_for_ticker(ticker, %{
          filing_type: :_424b5,
          filed_at: ~U[2026-03-01 00:00:00.000000Z]
        })

      build_filing_analysis(supplement, %{dilution_type: :atm, share_count: 10_000_000})

      assert AtmLifecycle.resolve(ticker.id, as_of: @as_of) == nil
    end

    test "returns nil when over-used (remaining < 0)" do
      ticker = build_ticker()

      s3 =
        build_filing_for_ticker(ticker, %{
          filing_type: :s3,
          filed_at: ~U[2026-02-15 00:00:00.000000Z]
        })

      build_filing_analysis(s3, %{dilution_type: :atm, atm_total_authorized_shares: 5_000_000})

      supplement =
        build_filing_for_ticker(ticker, %{
          filing_type: :_424b5,
          filed_at: ~U[2026-03-01 00:00:00.000000Z]
        })

      # Over-counted (LLM extractor error, etc.). Should still resolve
      # to nil rather than negative capacity.
      build_filing_analysis(supplement, %{dilution_type: :atm, share_count: 6_000_000})

      assert AtmLifecycle.resolve(ticker.id, as_of: @as_of) == nil
    end
  end

  describe "resolve/2 — dormancy" do
    test "returns nil when the last 424B5 is older than the dormancy cutoff (~180d)" do
      ticker = build_ticker()

      s3 =
        build_filing_for_ticker(ticker, %{
          filing_type: :s3,
          filed_at: ~U[2025-06-01 00:00:00.000000Z]
        })

      build_filing_analysis(s3, %{dilution_type: :atm, atm_total_authorized_shares: 20_000_000})

      # ~270 days before @as_of — well past 180d
      stale_supplement =
        build_filing_for_ticker(ticker, %{
          filing_type: :_424b5,
          filed_at: ~U[2025-08-01 00:00:00.000000Z]
        })

      build_filing_analysis(stale_supplement, %{dilution_type: :atm, share_count: 1_000_000})

      assert AtmLifecycle.resolve(ticker.id, as_of: @as_of) == nil
    end

    test "returns active when last 424B5 is within the dormancy cutoff" do
      ticker = build_ticker()

      s3 =
        build_filing_for_ticker(ticker, %{
          filing_type: :s3,
          filed_at: ~U[2025-06-01 00:00:00.000000Z]
        })

      build_filing_analysis(s3, %{dilution_type: :atm, atm_total_authorized_shares: 20_000_000})

      # ~80 days before @as_of — well within 180d
      recent_supplement =
        build_filing_for_ticker(ticker, %{
          filing_type: :_424b5,
          filed_at: ~U[2026-02-10 00:00:00.000000Z]
        })

      build_filing_analysis(recent_supplement, %{dilution_type: :atm, share_count: 1_000_000})

      result = AtmLifecycle.resolve(ticker.id, as_of: @as_of)
      assert result.remaining_shares == 19_000_000
    end

    test "returns active for a fresh registration with no 424B5 supplements yet" do
      ticker = build_ticker()

      # No supplement → no dormancy concern, regardless of registration age.
      old_s3 =
        build_filing_for_ticker(ticker, %{
          filing_type: :s3,
          filed_at: ~U[2025-01-01 00:00:00.000000Z]
        })

      build_filing_analysis(old_s3, %{dilution_type: :atm, atm_total_authorized_shares: 5_000_000})

      result = AtmLifecycle.resolve(ticker.id, as_of: @as_of)
      assert result.remaining_shares == 5_000_000
      assert result.last_424b_filed_at == nil
    end
  end

  describe "resolve/2 — multiple registrations" do
    test "picks the most recent S-3 and only counts supplements filed after it" do
      ticker = build_ticker()

      old_s3 =
        build_filing_for_ticker(ticker, %{
          filing_type: :s3,
          filed_at: ~U[2026-01-01 00:00:00.000000Z]
        })

      build_filing_analysis(old_s3, %{dilution_type: :atm, atm_total_authorized_shares: 5_000_000})

      # Supplement BEFORE the newer registration — usage of the OLD ATM,
      # not counted against the newer one.
      pre_supplement =
        build_filing_for_ticker(ticker, %{
          filing_type: :_424b5,
          filed_at: ~U[2026-02-15 00:00:00.000000Z]
        })

      build_filing_analysis(pre_supplement, %{dilution_type: :atm, share_count: 1_000_000})

      new_s3 =
        build_filing_for_ticker(ticker, %{
          filing_type: :s3,
          filed_at: ~U[2026-03-01 00:00:00.000000Z]
        })

      build_filing_analysis(new_s3, %{
        dilution_type: :atm,
        atm_total_authorized_shares: 20_000_000
      })

      post_supplement =
        build_filing_for_ticker(ticker, %{
          filing_type: :_424b5,
          filed_at: ~U[2026-04-01 00:00:00.000000Z]
        })

      build_filing_analysis(post_supplement, %{dilution_type: :atm, share_count: 2_000_000})

      result = AtmLifecycle.resolve(ticker.id, as_of: @as_of)

      assert result.remaining_shares == 18_000_000
      assert result.used_to_date == 2_000_000
      assert new_s3.id in result.source_filing_ids
      assert post_supplement.id in result.source_filing_ids
      # The pre-registration supplement and the older registration are
      # intentionally excluded — they belong to a different ATM cycle.
      refute pre_supplement.id in result.source_filing_ids
      refute old_s3.id in result.source_filing_ids
    end
  end

  describe "resolve/2 — extraction quality" do
    test "skips 424B5 supplements whose share_count is nil (LLM could not extract)" do
      ticker = build_ticker()

      s3 =
        build_filing_for_ticker(ticker, %{
          filing_type: :s3,
          filed_at: ~U[2026-02-15 00:00:00.000000Z]
        })

      build_filing_analysis(s3, %{dilution_type: :atm, atm_total_authorized_shares: 10_000_000})

      # Counted
      good =
        build_filing_for_ticker(ticker, %{
          filing_type: :_424b5,
          filed_at: ~U[2026-03-01 00:00:00.000000Z]
        })

      build_filing_analysis(good, %{dilution_type: :atm, share_count: 2_000_000})

      # Skipped — share_count nil means the LLM didn't pull a number
      # from this supplement. Better to under-count than to fail loudly.
      missing =
        build_filing_for_ticker(ticker, %{
          filing_type: :_424b5,
          filed_at: ~U[2026-03-15 00:00:00.000000Z]
        })

      build_filing_analysis(missing, %{dilution_type: :atm, share_count: nil})

      result = AtmLifecycle.resolve(ticker.id, as_of: @as_of)

      assert result.used_to_date == 2_000_000
      assert result.remaining_shares == 8_000_000
      refute missing.id in result.source_filing_ids
    end
  end
end
