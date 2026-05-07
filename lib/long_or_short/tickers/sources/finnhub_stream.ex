defmodule LongOrShort.Tickers.Sources.FinnhubStream do
  @moduledoc """
  WebSocket client for Finnhub real-time trade ticks.

  ## Subscription set

  The set of subscribed symbols is computed at connect-time and on every
  watchlist mutation. Composition (in priority order, deduplicated, capped):

    1. Every symbol that appears in any user's `WatchlistItem`, ordered
       oldest-first across all users (FIFO eviction when over cap).
    2. The static `tracked_tickers.txt` ingestion universe, used as a
       fallback so dashboard widgets show live prices for the global news
       set even before any user has built a watchlist.

  The cap defaults to 50 (Finnhub free-tier WebSocket limit) and is
  overridable via `:finnhub_ws_symbol_cap`. The tracked fallback can be
  disabled via `:finnhub_ws_use_tracked_fallback` for single-tenant
  deployments where "show prices only for what you watchlisted" is the
  cleaner semantic.

  ## Reactive subscription

  Subscribes to the global `"watchlist:any"` PubSub topic in
  `handle_connect/2`. On each `{:watchlist_changed, _}` message,
  recomputes the desired set, diffs it against the current subscriptions,
  and sends `subscribe`/`unsubscribe` frame deltas — no reconnect.

  ## Trade tick handling

  On each `type: "trade"` frame, the matching ticker's `last_price` is
  updated via `Tickers.update_ticker_price/2` and a
  `{:price_tick, symbol, decimal_price}` message is broadcast on the
  `"prices"` PubSub topic for LiveView consumption.

  ## Reconnect policy

  WebSockex's built-in reconnect handles transient network blips. State
  is reset on every (re)connect because the server forgets our
  subscriptions when the socket drops. On hard auth failures or repeated
  disconnects the supervisor restarts this GenServer (default OTP retry
  budget applies).

  ## No API key

  If `:finnhub_api_key` is missing or empty, `start_link/1` returns
  `:ignore` so the supervisor doesn't crash-loop. Useful in dev without
  a key set.
  """

  use WebSockex
  require Logger

  alias LongOrShort.Tickers
  alias LongOrShort.Tickers.Tracked
  alias LongOrShort.Tickers.WatchlistEvents

  @url "wss://ws.finnhub.io"
  @topic "prices"
  @default_cap 50

  @doc "PubSub topic on which `{:price_tick, symbol, decimal}` is broadcast."
  def topic, do: @topic

  def start_link(_opts) do
    case Application.get_env(:long_or_short, :finnhub_api_key) do
      key when is_binary(key) and key != "" ->
        do_start(key)

      _ ->
        Logger.info("FinnhubStream: no API key configured — not starting")
        :ignore
    end
  end

  defp do_start(api_key) do
    WebSockex.start_link(
      "#{@url}?token=#{api_key}",
      __MODULE__,
      %{subscribed: MapSet.new(), connected?: false},
      name: __MODULE__,
      handle_initial_conn_failure: true
    )
  end

  @impl WebSockex
  def handle_connect(_conn, state) do
    WatchlistEvents.subscribe_any()
    desired = compute_subscription_set()

    Logger.info(
      "FinnhubStream: connected, subscribing to #{length(desired)} symbols"
    )

    send(self(), {:subscribe_next, desired})
    {:ok, %{state | subscribed: MapSet.new(desired), connected?: true}}
  end

  @impl WebSockex
  def handle_disconnect(%{reason: reason}, state) do
    Logger.warning("FinnhubStream: disconnected — #{inspect(reason)}; reconnecting")
    {:reconnect, %{state | subscribed: MapSet.new(), connected?: false}}
  end

  @impl WebSockex
  def handle_info({:subscribe_next, []}, state), do: {:ok, state}

  def handle_info({:subscribe_next, [symbol | rest]}, state) do
    send(self(), {:subscribe_next, rest})

    if state.connected? do
      frame = {:text, Jason.encode!(%{type: "subscribe", symbol: symbol})}
      {:reply, frame, state}
    else
      {:ok, state}
    end
  end

  def handle_info({:unsubscribe_next, []}, state), do: {:ok, state}

  def handle_info({:unsubscribe_next, [symbol | rest]}, state) do
    send(self(), {:unsubscribe_next, rest})

    if state.connected? do
      frame = {:text, Jason.encode!(%{type: "unsubscribe", symbol: symbol})}
      {:reply, frame, state}
    else
      {:ok, state}
    end
  end

  def handle_info({:watchlist_changed, _user_id}, state) do
    if state.connected? do
      desired = compute_subscription_set() |> MapSet.new()
      {to_add, to_remove} = diff_subscriptions(state.subscribed, desired)

      if to_add != [], do: send(self(), {:subscribe_next, to_add})
      if to_remove != [], do: send(self(), {:unsubscribe_next, to_remove})

      Logger.info(
        "FinnhubStream: watchlist changed — +#{length(to_add)} / -#{length(to_remove)} symbols"
      )

      {:ok, %{state | subscribed: desired}}
    else
      # While disconnected, defer to the next handle_connect/2 — it will
      # recompute the desired set fresh from the DB anyway.
      {:ok, state}
    end
  end

  @impl WebSockex
  def handle_frame({:text, body}, state) do
    case Jason.decode(body) do
      {:ok, %{"type" => "trade", "data" => trades}} when is_list(trades) ->
        Enum.each(trades, &process_trade/1)

      {:ok, %{"type" => "ping"}} ->
        :ok

      _ ->
        :ok
    end

    {:ok, state}
  end

  @doc """
  The capped, deduplicated symbol set the WebSocket should be subscribed to.

  Pure-ish: reads from the DB (`Tickers.all_watchlist_symbols/0`), file
  (`Tracked.symbols/0`), and Application env (cap + fallback toggle), but
  takes no arguments. Public for testing.
  """
  @spec compute_subscription_set() :: [String.t()]
  def compute_subscription_set do
    cap =
      Application.get_env(:long_or_short, :finnhub_ws_symbol_cap, @default_cap)

    use_tracked? =
      Application.get_env(:long_or_short, :finnhub_ws_use_tracked_fallback, true)

    watchlist_syms = Tickers.all_watchlist_symbols()
    tracked_syms = if use_tracked?, do: Tracked.symbols(), else: []

    (watchlist_syms ++ tracked_syms)
    |> Enum.uniq()
    |> Enum.take(cap)
  end

  @doc """
  Diff two subscription sets. Returns `{to_add, to_remove}` as plain
  lists — `to_add` is `desired \\ current`, `to_remove` is `current \\ desired`.

  Pure. Public for testing.
  """
  @spec diff_subscriptions(MapSet.t(String.t()), MapSet.t(String.t())) ::
          {[String.t()], [String.t()]}
  def diff_subscriptions(current, desired) do
    to_add = MapSet.difference(desired, current) |> Enum.to_list()
    to_remove = MapSet.difference(current, desired) |> Enum.to_list()
    {to_add, to_remove}
  end

  # Public for tests — does the per-tick work in isolation.
  @doc false
  def process_trade(%{"s" => symbol, "p" => price})
      when is_binary(symbol) and is_number(price) and price > 0 do
    decimal = Decimal.new(to_string(price))

    with {:ok, ticker} <- Tickers.get_ticker_by_symbol(symbol, authorize?: false),
         {:ok, _} <- Tickers.update_ticker_price(ticker, decimal, authorize?: false) do
      Phoenix.PubSub.broadcast(
        LongOrShort.PubSub,
        @topic,
        {:price_tick, symbol, decimal}
      )
    else
      _ -> :ok
    end
  end

  def process_trade(_), do: :ok
end
