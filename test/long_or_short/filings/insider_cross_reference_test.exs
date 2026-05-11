defmodule LongOrShort.Filings.InsiderCrossReferenceTest do
  @moduledoc """
  Tests for `LongOrShort.Filings.InsiderCrossReference` — LON-118.

  Pins `:as_of` for deterministic dates regardless of when the
  suite runs. Each scenario sets up Filings + InsiderTransactions
  on a fresh ticker and asserts whether the flag fires.
  """

  use LongOrShort.DataCase, async: true

  import LongOrShort.FilingsFixtures
  import LongOrShort.TickersFixtures

  alias LongOrShort.Filings.InsiderCrossReference

  # Reference clock for all tests.
  @as_of ~U[2026-05-01 00:00:00.000000Z]

  describe "insider_selling_post_dilution?/2 — true cases" do
    test "open-market sale 5 days after a dilution filing → true" do
      ticker = build_ticker()

      _dilution =
        build_filing_for_ticker(ticker, %{
          filing_type: :s3,
          filed_at: ~U[2026-04-10 12:00:00.000000Z]
        })

      form4 =
        build_filing_for_ticker(ticker, %{
          filing_type: :form4,
          filed_at: ~U[2026-04-15 12:00:00.000000Z]
        })

      build_insider_transaction(form4, %{
        transaction_code: :open_market_sale,
        transaction_date: ~D[2026-04-15]
      })

      assert InsiderCrossReference.insider_selling_post_dilution?(ticker.id, as_of: @as_of) ==
               true
    end

    test "sale on the same day as the dilution filing → true (boundary inclusive)" do
      ticker = build_ticker()

      build_filing_for_ticker(ticker, %{
        filing_type: :_8k,
        filed_at: ~U[2026-04-15 09:00:00.000000Z]
      })

      form4 =
        build_filing_for_ticker(ticker, %{
          filing_type: :form4,
          filed_at: ~U[2026-04-15 16:00:00.000000Z]
        })

      build_insider_transaction(form4, %{
        transaction_code: :open_market_sale,
        transaction_date: ~D[2026-04-15]
      })

      assert InsiderCrossReference.insider_selling_post_dilution?(ticker.id, as_of: @as_of) ==
               true
    end
  end

  describe "insider_selling_post_dilution?/2 — false cases" do
    test "no dilution filing → false (post-dilution requires a preceding filing)" do
      ticker = build_ticker()

      # Form 4 with insider sale, but no dilution filing at all.
      # The "post-dilution" framing means the flag is false without
      # a dilution event to anchor against.
      form4 =
        build_filing_for_ticker(ticker, %{
          filing_type: :form4,
          filed_at: ~U[2026-04-15 12:00:00.000000Z]
        })

      build_insider_transaction(form4, %{
        transaction_code: :open_market_sale,
        transaction_date: ~D[2026-04-15]
      })

      assert InsiderCrossReference.insider_selling_post_dilution?(ticker.id, as_of: @as_of) ==
               false
    end

    test "sale 100 days after dilution filing → false (outside 30-day window)" do
      ticker = build_ticker()

      build_filing_for_ticker(ticker, %{
        filing_type: :s3,
        filed_at: ~U[2026-01-01 00:00:00.000000Z]
      })

      form4 =
        build_filing_for_ticker(ticker, %{
          filing_type: :form4,
          filed_at: ~U[2026-04-15 12:00:00.000000Z]
        })

      build_insider_transaction(form4, %{
        transaction_code: :open_market_sale,
        transaction_date: ~D[2026-04-15]
      })

      assert InsiderCrossReference.insider_selling_post_dilution?(ticker.id, as_of: @as_of) ==
               false
    end

    test "sale before the dilution filing → false (must be post-dilution)" do
      ticker = build_ticker()

      build_filing_for_ticker(ticker, %{
        filing_type: :s3,
        filed_at: ~U[2026-04-20 00:00:00.000000Z]
      })

      form4 =
        build_filing_for_ticker(ticker, %{
          filing_type: :form4,
          filed_at: ~U[2026-04-15 00:00:00.000000Z]
        })

      build_insider_transaction(form4, %{
        transaction_code: :open_market_sale,
        transaction_date: ~D[2026-04-15]
      })

      assert InsiderCrossReference.insider_selling_post_dilution?(ticker.id, as_of: @as_of) ==
               false
    end

    test "exercise (M) within window → false (only open_market_sale counts)" do
      ticker = build_ticker()

      build_filing_for_ticker(ticker, %{
        filing_type: :s3,
        filed_at: ~U[2026-04-10 00:00:00.000000Z]
      })

      form4 =
        build_filing_for_ticker(ticker, %{
          filing_type: :form4,
          filed_at: ~U[2026-04-15 00:00:00.000000Z]
        })

      build_insider_transaction(form4, %{
        transaction_code: :exercise,
        transaction_date: ~D[2026-04-15]
      })

      assert InsiderCrossReference.insider_selling_post_dilution?(ticker.id, as_of: @as_of) ==
               false
    end

    test "only Form 4 exists (no other filing types) → false" do
      ticker = build_ticker()

      # Form 4 itself doesn't count as a dilution event — it's the
      # insider signal. Without an actual dilution filing
      # (S-3 / 8-K / etc.), the flag stays false even with a sale.
      form4 =
        build_filing_for_ticker(ticker, %{
          filing_type: :form4,
          filed_at: ~U[2026-04-10 00:00:00.000000Z]
        })

      build_insider_transaction(form4, %{
        transaction_code: :open_market_sale,
        transaction_date: ~D[2026-04-15]
      })

      assert InsiderCrossReference.insider_selling_post_dilution?(ticker.id, as_of: @as_of) ==
               false
    end

    test "ticker with no filings or transactions → false" do
      ticker = build_ticker()
      assert InsiderCrossReference.insider_selling_post_dilution?(ticker.id, as_of: @as_of) ==
               false
    end
  end

  describe "insider_selling_post_dilution?/2 — window override" do
    test ":window_days opt overrides the default" do
      ticker = build_ticker()

      build_filing_for_ticker(ticker, %{
        filing_type: :s3,
        filed_at: ~U[2026-04-01 00:00:00.000000Z]
      })

      form4 =
        build_filing_for_ticker(ticker, %{
          filing_type: :form4,
          filed_at: ~U[2026-04-15 00:00:00.000000Z]
        })

      build_insider_transaction(form4, %{
        transaction_code: :open_market_sale,
        transaction_date: ~D[2026-04-15]
      })

      # 30-day default window — sale is 14 days after filing → true
      assert InsiderCrossReference.insider_selling_post_dilution?(ticker.id, as_of: @as_of) ==
               true

      # 7-day override — sale is outside → false
      assert InsiderCrossReference.insider_selling_post_dilution?(
               ticker.id,
               as_of: @as_of,
               window_days: 7
             ) == false
    end
  end

  describe "insider_selling_post_dilution?/2 — multiple dilution filings" do
    test "anchors against the latest dilution filing, not earlier ones" do
      ticker = build_ticker()

      # Old dilution filing — sale 5d after this would be in-window
      # if anchored on the old one, but the recent filing pushes the
      # anchor forward.
      build_filing_for_ticker(ticker, %{
        filing_type: :s1,
        filed_at: ~U[2025-12-01 00:00:00.000000Z]
      })

      # New dilution filing — much later, sale would be 130d+ after
      # this.
      build_filing_for_ticker(ticker, %{
        filing_type: :s3,
        filed_at: ~U[2026-04-20 00:00:00.000000Z]
      })

      form4 =
        build_filing_for_ticker(ticker, %{
          filing_type: :form4,
          filed_at: ~U[2025-12-05 00:00:00.000000Z]
        })

      build_insider_transaction(form4, %{
        transaction_code: :open_market_sale,
        transaction_date: ~D[2025-12-05]
      })

      # Anchor is the 2026-04-20 S-3 → sale was BEFORE that → false.
      assert InsiderCrossReference.insider_selling_post_dilution?(ticker.id, as_of: @as_of) ==
               false
    end
  end
end
