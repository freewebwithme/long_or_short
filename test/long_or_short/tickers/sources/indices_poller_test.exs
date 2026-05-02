defmodule LongOrShort.Tickers.Sources.IndicesPollerTest do
  use ExUnit.Case, async: true

  alias LongOrShort.Indices.Events
  alias LongOrShort.Tickers.Sources.IndicesPoller

  describe "build_payload/2" do
    test "converts Finnhub /quote response into a typed payload" do
      body = %{"c" => 420.13, "dp" => 0.84, "pc" => 416.62}

      payload = IndicesPoller.build_payload("DIA", body)

      assert payload.symbol == "DIA"
      assert Decimal.compare(payload.current, Decimal.new("420.13")) == :eq
      assert Decimal.compare(payload.change_pct, Decimal.new("0.84")) == :eq
      assert Decimal.compare(payload.prev_close, Decimal.new("416.62")) == :eq
      assert %DateTime{} = payload.fetched_at
    end

    test "handles missing/non-numeric fields by defaulting to 0" do
      payload = IndicesPoller.build_payload("DIA", %{})

      assert Decimal.compare(payload.current, Decimal.new(0)) == :eq
      assert Decimal.compare(payload.change_pct, Decimal.new(0)) == :eq
    end
  end

  describe "indices/0" do
    test "exposes the three required indices in order" do
      assert IndicesPoller.indices() == [
               {"DJIA", "DIA"},
               {"NASDAQ-100", "QQQ"},
               {"S&P 500", "SPY"}
             ]
    end
  end

  describe "broadcast contract" do
    test "Events.broadcast emits the agreed tuple shape that the poller uses" do
      Events.subscribe()

      payload = IndicesPoller.build_payload("DIA", %{"c" => 1, "dp" => 0, "pc" => 1})
      Events.broadcast("DJIA", payload)

      assert_receive {:index_tick, "DJIA", %{symbol: "DIA"}}, 100
    end
  end
end
