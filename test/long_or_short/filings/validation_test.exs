defmodule LongOrShort.Filings.ValidationTest do
  @moduledoc """
  Tests for `LongOrShort.Filings.Validation`.

  Pure-function module. Inline struct fixtures avoid the DataCase
  overhead since no DB roundtrip is needed.
  """

  use ExUnit.Case, async: true

  alias LongOrShort.Filings.{Filing, Validation}
  alias LongOrShort.Tickers.Ticker

  # ── Inline struct helpers ──────────────────────────────────────

  defp filing(attrs \\ %{}) do
    defaults = %{
      id: "00000000-0000-0000-0000-000000000001",
      source: :sec_edgar,
      filing_type: :_8k,
      filing_subtype: nil,
      external_id: "ext-1",
      filer_cik: "0001234567",
      filed_at: DateTime.utc_now(),
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

  # ── share_count ────────────────────────────────────────────────

  describe "share_count_positive check" do
    test "passes when nil" do
      assert :ok = Validation.validate(%{share_count: nil}, filing(), ticker())
    end

    test "passes when positive integer" do
      assert :ok = Validation.validate(%{share_count: 1_000_000}, filing(), ticker())
    end

    test "rejects zero" do
      assert {:error, {:rejected, :share_count_positive, %{share_count: 0}}} =
               Validation.validate(%{share_count: 0}, filing(), ticker())
    end

    test "rejects negative" do
      assert {:error, {:rejected, :share_count_positive, %{share_count: -100}}} =
               Validation.validate(%{share_count: -100}, filing(), ticker())
    end
  end

  # ── deal_size_usd ──────────────────────────────────────────────

  describe "deal_size_positive check" do
    test "passes when nil" do
      assert :ok = Validation.validate(%{deal_size_usd: nil}, filing(), ticker())
    end

    test "passes when positive" do
      assert :ok = Validation.validate(%{deal_size_usd: 1_000_000}, filing(), ticker())
    end

    test "rejects zero" do
      assert {:error, {:rejected, :deal_size_positive, _}} =
               Validation.validate(%{deal_size_usd: 0}, filing(), ticker())
    end

    test "rejects negative" do
      assert {:error, {:rejected, :deal_size_positive, _}} =
               Validation.validate(%{deal_size_usd: -100}, filing(), ticker())
    end
  end

  # ── pricing_discount_pct ───────────────────────────────────────

  describe "pricing_discount_range check" do
    test "passes when nil" do
      assert :ok = Validation.validate(%{pricing_discount_pct: nil}, filing(), ticker())
    end

    test "passes at lower boundary -50" do
      assert :ok = Validation.validate(%{pricing_discount_pct: -50}, filing(), ticker())
    end

    test "passes at upper boundary 50" do
      assert :ok = Validation.validate(%{pricing_discount_pct: 50}, filing(), ticker())
    end

    test "rejects below -50" do
      assert {:error, {:rejected, :pricing_discount_range, _}} =
               Validation.validate(%{pricing_discount_pct: -50.1}, filing(), ticker())
    end

    test "rejects above 50" do
      assert {:error, {:rejected, :pricing_discount_range, _}} =
               Validation.validate(%{pricing_discount_pct: 75}, filing(), ticker())
    end
  end

  # ── warrant_strike ─────────────────────────────────────────────

  describe "warrant_strike_positive check" do
    test "passes when nil" do
      assert :ok = Validation.validate(%{warrant_strike: nil}, filing(), ticker())
    end

    test "passes when positive" do
      assert :ok = Validation.validate(%{warrant_strike: 1.50}, filing(), ticker())
    end

    test "rejects zero" do
      assert {:error, {:rejected, :warrant_strike_positive, _}} =
               Validation.validate(%{warrant_strike: 0}, filing(), ticker())
    end

    test "rejects negative" do
      assert {:error, {:rejected, :warrant_strike_positive, _}} =
               Validation.validate(%{warrant_strike: -1}, filing(), ticker())
    end
  end

  # ── reverse_split_ratio_format ─────────────────────────────────

  describe "reverse_split_ratio_format check" do
    test "passes when nil" do
      assert :ok = Validation.validate(%{reverse_split_ratio: nil}, filing(), ticker())
    end

    test "accepts colon format" do
      assert :ok = Validation.validate(%{reverse_split_ratio: "1:10"}, filing(), ticker())
    end

    test "accepts hyphenated for-format" do
      assert :ok = Validation.validate(%{reverse_split_ratio: "1-for-10"}, filing(), ticker())
    end

    test "accepts spaced for-format" do
      assert :ok = Validation.validate(%{reverse_split_ratio: "1 for 10"}, filing(), ticker())
    end

    test "rejects free-form prose" do
      assert {:error, {:rejected, :reverse_split_ratio_format, _}} =
               Validation.validate(
                 %{reverse_split_ratio: "approximately one for ten"},
                 filing(),
                 ticker()
               )
    end
  end

  # ── share_count_bound (cross-ref with shares_outstanding) ──────

  describe "share_count_bound check" do
    test "passes within bound" do
      assert :ok =
               Validation.validate(
                 %{share_count: 50_000_000},
                 filing(),
                 ticker(%{shares_outstanding: 20_000_000})
               )
    end

    test "passes at exact 10× boundary" do
      assert :ok =
               Validation.validate(
                 %{share_count: 200_000_000},
                 filing(),
                 ticker(%{shares_outstanding: 20_000_000})
               )
    end

    test "rejects beyond 10× shares_outstanding (catches 12M-as-12B)" do
      assert {:error,
              {:rejected, :share_count_bound,
               %{share_count: 12_000_000_000, shares_outstanding: 20_000_000}}} =
               Validation.validate(
                 %{share_count: 12_000_000_000},
                 filing(),
                 ticker(%{shares_outstanding: 20_000_000})
               )
    end

    test "skipped when shares_outstanding missing on ticker" do
      assert :ok =
               Validation.validate(
                 %{share_count: 999_999_999_999},
                 filing(),
                 ticker(%{shares_outstanding: nil})
               )
    end
  end

  # ── implied_price_sane ─────────────────────────────────────────

  describe "implied_price_sane check" do
    # ticker last_price = $5.00, allowed band = $2.50–$10.00

    test "passes when implied price equals last_price" do
      # 1M shares × $5 = $5M deal
      assert :ok =
               Validation.validate(
                 %{
                   pricing_method: :fixed,
                   share_count: 1_000_000,
                   deal_size_usd: 5_000_000
                 },
                 filing(),
                 ticker()
               )
    end

    test "passes within 0.5×–2× band" do
      # implied $3 (0.6× of $5)
      assert :ok =
               Validation.validate(
                 %{
                   pricing_method: :fixed,
                   share_count: 1_000_000,
                   deal_size_usd: 3_000_000
                 },
                 filing(),
                 ticker()
               )
    end

    test "rejects implied price outside 0.5×–2× band" do
      # implied $0.10 (way below $2.50 lower bound)
      assert {:error, {:rejected, :implied_price_sane, _}} =
               Validation.validate(
                 %{
                   pricing_method: :fixed,
                   share_count: 1_000_000,
                   deal_size_usd: 100_000
                 },
                 filing(),
                 ticker()
               )
    end

    test "skipped when pricing_method is not :fixed" do
      assert :ok =
               Validation.validate(
                 %{
                   pricing_method: :vwap_based,
                   share_count: 1_000_000,
                   deal_size_usd: 100_000
                 },
                 filing(),
                 ticker()
               )
    end

    test "skipped when last_price missing" do
      assert :ok =
               Validation.validate(
                 %{
                   pricing_method: :fixed,
                   share_count: 1_000_000,
                   deal_size_usd: 100_000
                 },
                 filing(),
                 ticker(%{last_price: nil})
               )
    end
  end

  # ── filer_cik_matches_ticker ───────────────────────────────────

  describe "filer_cik_matches_ticker check" do
    test "passes on exact CIK match" do
      assert :ok =
               Validation.validate(
                 %{},
                 filing(%{filer_cik: "0001234567"}),
                 ticker(%{cik: "0001234567"})
               )
    end

    test "passes ignoring zero-padding differences" do
      assert :ok =
               Validation.validate(
                 %{},
                 filing(%{filer_cik: "0001234567"}),
                 ticker(%{cik: "1234567"})
               )
    end

    test "rejects on mismatch" do
      assert {:error,
              {:rejected, :filer_cik_matches_ticker,
               %{filer_cik: "0009999999", ticker_cik: "0001234567"}}} =
               Validation.validate(
                 %{},
                 filing(%{filer_cik: "0009999999"}),
                 ticker(%{cik: "0001234567"})
               )
    end

    test "skipped when ticker has no CIK recorded" do
      assert :ok =
               Validation.validate(
                 %{},
                 filing(%{filer_cik: "0009999999"}),
                 ticker(%{cik: nil})
               )
    end
  end

  # ── Multi-check fail-fast ─────────────────────────────────────

  describe "fail-fast ordering" do
    test "first failed check wins; later violations not reported" do
      # Both share_count and deal_size_usd are negative; first check
      # in the with-pipe (share_count) should be the one reported.
      assert {:error, {:rejected, :share_count_positive, _}} =
               Validation.validate(
                 %{share_count: -1, deal_size_usd: -1},
                 filing(),
                 ticker()
               )
    end
  end

  describe "happy path — all valid" do
    test "passes a fully populated valid extraction" do
      extraction = %{
        dilution_type: :pipe,
        share_count: 1_000_000,
        deal_size_usd: 5_000_000,
        pricing_method: :fixed,
        pricing_discount_pct: 10.0,
        warrant_strike: 1.5,
        warrant_term_years: 5,
        reverse_split_ratio: nil
      }

      assert :ok = Validation.validate(extraction, filing(), ticker())
    end
  end
end
