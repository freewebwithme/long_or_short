defmodule LongOrShort.Tickers.Sources.FinnhubStreamTest do
  use LongOrShort.DataCase, async: false

  import LongOrShort.TickersFixtures

  alias LongOrShort.Tickers
  alias LongOrShort.Tickers.Sources.FinnhubStream

  describe "process_trade/1" do
    setup do
      Phoenix.PubSub.subscribe(LongOrShort.PubSub, FinnhubStream.topic())
      :ok
    end

    test "updates last_price and broadcasts on a known symbol" do
      build_ticker(%{symbol: "AAPL"})

      FinnhubStream.process_trade(%{"s" => "AAPL", "p" => 215.42})

      assert_receive {:price_tick, "AAPL", %Decimal{} = price}
      assert Decimal.compare(price, Decimal.new("215.42")) == :eq

      {:ok, t} = Tickers.get_ticker_by_symbol("AAPL", authorize?: false)
      assert Decimal.compare(t.last_price, Decimal.new("215.42")) == :eq
      assert t.last_price_updated_at
    end

    test "no-op on unknown symbol — no broadcast" do
      FinnhubStream.process_trade(%{"s" => "NOPE", "p" => 10.0})
      refute_receive {:price_tick, _, _}, 100
    end

    test "rejects non-positive price" do
      build_ticker(%{symbol: "AAPL"})
      FinnhubStream.process_trade(%{"s" => "AAPL", "p" => 0})
      FinnhubStream.process_trade(%{"s" => "AAPL", "p" => -1.5})
      refute_receive {:price_tick, _, _}, 100
    end

    test "handles integer price" do
      build_ticker(%{symbol: "AAPL"})
      FinnhubStream.process_trade(%{"s" => "AAPL", "p" => 100})
      assert_receive {:price_tick, "AAPL", %Decimal{}}
    end

    test "ignores malformed payload" do
      FinnhubStream.process_trade(%{})
      FinnhubStream.process_trade(%{"s" => "AAPL"})
      FinnhubStream.process_trade(%{"p" => 10.0})
      refute_receive {:price_tick, _, _}, 100
    end
  end

  describe "live WebSocket — @tag :external" do
    @tag :external
    test "connects and receives at least one trade tick within 30s" do
      Application.put_env(
        :long_or_short,
        :finnhub_api_key,
        System.get_env("FINNHUB_API_KEY")
      )

      build_ticker(%{symbol: "AAPL"})
      Phoenix.PubSub.subscribe(LongOrShort.PubSub, FinnhubStream.topic())

      {:ok, pid} = FinnhubStream.start_link([])
      Ecto.Adapters.SQL.Sandbox.allow(LongOrShort.Repo, self(), pid)

      # Note: depends on US market hours — outside RTH this will time out.
      assert_receive {:price_tick, _, _}, 30_000

      GenServer.stop(pid)
    end
  end
end
