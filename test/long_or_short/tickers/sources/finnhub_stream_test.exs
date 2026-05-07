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

  describe "compute_subscription_set/0" do
    setup do
      original_tracked = Application.get_env(:long_or_short, :tracked_tickers_override)
      original_cap = Application.get_env(:long_or_short, :finnhub_ws_symbol_cap)

      original_fallback =
        Application.get_env(:long_or_short, :finnhub_ws_use_tracked_fallback)

      on_exit(fn ->
        restore(:tracked_tickers_override, original_tracked)
        restore(:finnhub_ws_symbol_cap, original_cap)
        restore(:finnhub_ws_use_tracked_fallback, original_fallback)
      end)

      :ok
    end

    test "no watchlists — falls back to tracked symbols" do
      Application.put_env(:long_or_short, :tracked_tickers_override, ~w(AAPL TSLA))

      assert FinnhubStream.compute_subscription_set() == ["AAPL", "TSLA"]
    end

    test "watchlist symbols come before tracked fallback" do
      aapl = build_ticker(%{symbol: "AAPL"})
      tsla = build_ticker(%{symbol: "TSLA"})
      build_watchlist_item(%{ticker_id: aapl.id})
      build_watchlist_item(%{ticker_id: tsla.id})

      Application.put_env(:long_or_short, :tracked_tickers_override, ~w(NVDA))

      assert FinnhubStream.compute_subscription_set() == ["AAPL", "TSLA", "NVDA"]
    end

    test "cap evicts tracked symbols before watchlist symbols" do
      aapl = build_ticker(%{symbol: "AAPL"})
      tsla = build_ticker(%{symbol: "TSLA"})
      build_watchlist_item(%{ticker_id: aapl.id})
      build_watchlist_item(%{ticker_id: tsla.id})

      Application.put_env(:long_or_short, :tracked_tickers_override, ~w(NVDA AMZN))
      Application.put_env(:long_or_short, :finnhub_ws_symbol_cap, 2)

      assert FinnhubStream.compute_subscription_set() == ["AAPL", "TSLA"]
    end

    test "within watchlists, cap evicts newest first (FIFO)" do
      aapl = build_ticker(%{symbol: "AAPL"})
      tsla = build_ticker(%{symbol: "TSLA"})
      nvda = build_ticker(%{symbol: "NVDA"})

      build_watchlist_item(%{ticker_id: aapl.id})
      build_watchlist_item(%{ticker_id: tsla.id})
      build_watchlist_item(%{ticker_id: nvda.id})

      Application.put_env(:long_or_short, :tracked_tickers_override, [])
      Application.put_env(:long_or_short, :finnhub_ws_symbol_cap, 2)

      assert FinnhubStream.compute_subscription_set() == ["AAPL", "TSLA"]
    end

    test "tracked fallback disabled — only watchlist symbols" do
      aapl = build_ticker(%{symbol: "AAPL"})
      build_watchlist_item(%{ticker_id: aapl.id})

      Application.put_env(:long_or_short, :tracked_tickers_override, ~w(NVDA AMZN))
      Application.put_env(:long_or_short, :finnhub_ws_use_tracked_fallback, false)

      assert FinnhubStream.compute_subscription_set() == ["AAPL"]
    end

    test "deduplicates symbols that appear in both watchlist and tracked" do
      aapl = build_ticker(%{symbol: "AAPL"})
      build_watchlist_item(%{ticker_id: aapl.id})

      Application.put_env(:long_or_short, :tracked_tickers_override, ~w(AAPL NVDA))

      assert FinnhubStream.compute_subscription_set() == ["AAPL", "NVDA"]
    end
  end

  describe "diff_subscriptions/2" do
    test "empty current — everything is to_add" do
      current = MapSet.new()
      desired = MapSet.new(["AAPL", "TSLA"])

      assert {to_add, []} = FinnhubStream.diff_subscriptions(current, desired)
      assert Enum.sort(to_add) == ["AAPL", "TSLA"]
    end

    test "empty desired — everything is to_remove" do
      current = MapSet.new(["AAPL", "TSLA"])
      desired = MapSet.new()

      assert {[], to_remove} = FinnhubStream.diff_subscriptions(current, desired)
      assert Enum.sort(to_remove) == ["AAPL", "TSLA"]
    end

    test "overlap — only the diff" do
      current = MapSet.new(["AAPL", "TSLA"])
      desired = MapSet.new(["TSLA", "NVDA"])

      assert {to_add, to_remove} = FinnhubStream.diff_subscriptions(current, desired)
      assert Enum.sort(to_add) == ["NVDA"]
      assert Enum.sort(to_remove) == ["AAPL"]
    end

    test "identical sets — both diffs empty" do
      set = MapSet.new(["AAPL", "TSLA"])
      assert {[], []} = FinnhubStream.diff_subscriptions(set, set)
    end
  end

  defp restore(key, nil), do: Application.delete_env(:long_or_short, key)
  defp restore(key, value), do: Application.put_env(:long_or_short, key, value)

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
