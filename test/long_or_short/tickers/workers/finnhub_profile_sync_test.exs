defmodule LongOrShort.Tickers.Workers.FinnhubProfileSyncTest do
  use LongOrShort.DataCase, async: true

  alias LongOrShort.Tickers
  alias LongOrShort.Tickers.Workers.FinnhubProfileSync

  describe "build_attrs/2" do
    test "maps shareOutstanding millions → integer for both share fields" do
      attrs =
        FinnhubProfileSync.build_attrs("BTBD", %{
          "name" => "Bt Brands Inc",
          "exchange" => "NASDAQ NMS - GLOBAL MARKET",
          "finnhubIndustry" => "Hotels, Restaurants & Leisure",
          "shareOutstanding" => 6.15
        })

      assert attrs.symbol == "BTBD"
      assert attrs.company_name == "Bt Brands Inc"
      assert attrs.exchange == :nasdaq
      assert attrs.industry == "Hotels, Restaurants & Leisure"
      assert attrs.shares_outstanding == 6_150_000
      assert attrs.float_shares == 6_150_000
    end

    test "maps NYSE exchange string" do
      attrs =
        FinnhubProfileSync.build_attrs("AAPL", %{
          "exchange" => "NEW YORK STOCK EXCHANGE, INC.",
          "shareOutstanding" => 16_350.34
        })

      assert attrs.exchange == :nyse
      assert attrs.shares_outstanding == 16_350_340_000
    end

    test "leaves share counts nil when shareOutstanding is missing or 0" do
      attrs = FinnhubProfileSync.build_attrs("X", %{})
      assert is_nil(attrs.shares_outstanding)
      assert is_nil(attrs.float_shares)
    end

    test "unknown exchange string falls back to :other when no substring matches" do
      attrs = FinnhubProfileSync.build_attrs("X", %{"exchange" => "Some Foreign Bourse"})
      assert attrs.exchange == :other
    end
  end

  describe "perform/1 — live Finnhub call" do
    @tag :external
    test "syncs profile for AAPL against the real API" do
      {:ok, _} =
        Tickers.upsert_ticker_by_symbol(%{symbol: "AAPL"}, authorize?: false)

      assert :ok = FinnhubProfileSync.perform(%Oban.Job{args: %{}})

      {:ok, t} = Tickers.get_ticker_by_symbol("AAPL", authorize?: false)
      assert t.exchange in [:nasdaq, :nyse]
      assert is_integer(t.shares_outstanding) and t.shares_outstanding > 0
    end
  end
end
