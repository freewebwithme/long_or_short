defmodule LongOrShort.Tickers.Sources.IwmHoldingsTest do
  use ExUnit.Case, async: true

  alias LongOrShort.Tickers.Sources.IwmHoldings

  @fixture_path "test/fixtures/iwm/iwm_holdings_sample.csv"

  describe "parse_holdings/1" do
    setup do
      {:ok, csv: File.read!(@fixture_path)}
    end

    test "extracts only Equity rows", %{csv: csv} do
      assert {:ok, holdings} = IwmHoldings.parse_holdings(csv)
      assert length(holdings) == 5
    end

    test "uppercases and orders symbols as they appear", %{csv: csv} do
      {:ok, holdings} = IwmHoldings.parse_holdings(csv)

      assert Enum.map(holdings, & &1.symbol) ==
               ["BE", "CRDO", "FAKEARCA", "FAKEBATS", "FAKEAMEX"]
    end

    test "maps Exchange column to the Ticker.exchange enum", %{csv: csv} do
      {:ok, holdings} = IwmHoldings.parse_holdings(csv)
      by_symbol = Map.new(holdings, &{&1.symbol, &1.exchange})

      assert by_symbol["BE"] == :nyse
      assert by_symbol["CRDO"] == :nasdaq
      assert by_symbol["FAKEARCA"] == :nyse
      assert by_symbol["FAKEBATS"] == :other
      assert by_symbol["FAKEAMEX"] == :amex
    end

    test "converts iShares' '-' sentinel to nil", %{csv: csv} do
      {:ok, holdings} = IwmHoldings.parse_holdings(csv)
      by_symbol = Map.new(holdings, &{&1.symbol, &1.sector})

      assert by_symbol["BE"] == "Industrials"
      assert by_symbol["FAKEBATS"] == nil
    end

    test "drops the footer disclaimer rows", %{csv: csv} do
      {:ok, holdings} = IwmHoldings.parse_holdings(csv)

      refute Enum.any?(holdings, fn h ->
               String.contains?(h.symbol, "BLACKROCK") or
                 String.contains?(h.name || "", "owned or licensed")
             end)
    end

    test "returns :header_not_found when the Ticker header row is missing" do
      assert {:error, :header_not_found} =
               IwmHoldings.parse_holdings("garbage,not,csv\nstill,no,header\n")
    end
  end
end
