defmodule LongOrShort.Tickers.Sources.FinnhubStream do
  @moduledoc """
  WebSocket client for Finnhub real-time trade ticks.

  Subscribes to every symbol in `LongOrShort.Tickers.Watchlist` on
  connect. On each `type: "trade"` frame, the matching ticker's
  `last_price` is updated via `Tickers.update_ticker_price/2` and a
  `{:price_tick, symbol, decimal_price}` message is broadcast on
  the `"prices"` PubSub topic for LiveView consumption.

  Free tier covers up to 50 simultaneous subscriptions — that's the
  hard upper bound until we shard or upgrade.

  ## Reconnect policy

  WebSockex's built-in reconnect handles transient network blips.
  On hard auth failures or repeated disconnects the supervisor
  restarts this GenServer (default OTP retry budget applies).

  ## No API key

  If `:finnhub_api_key` is missing or empty, `start_link/1` returns
  `:ignore` so the supervisor doesn't crash-loop. Useful in dev
  without a key set.
  """

  use WebSockex
  require Logger

  alias LongOrShort.Tickers
  alias LongOrShort.Tickers.Watchlist

  @url "wss://ws.finnhub.io"
  @topic "prices"

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
    symbols = Watchlist.symbols()

    WebSockex.start_link(
      "#{@url}?token=#{api_key}",
      __MODULE__,
      %{symbols: symbols},
      name: __MODULE__,
      handle_initial_conn_failure: true
    )
  end

  @impl WebSockex
  def handle_connect(_conn, %{symbols: symbols} = state) do
    Logger.info("FinnhubStream: connected, subscribing to #{length(symbols)} symbols")
    send(self(), {:subscribe_next, symbols})
    {:ok, state}
  end

  @impl WebSockex
  def handle_info({:subscribe_next, []}, state), do: {:ok, state}

  def handle_info({:subscribe_next, [symbol | rest]}, state) do
    send(self(), {:subscribe_next, rest})
    frame = {:text, Jason.encode!(%{type: "subscribe", symbol: symbol})}
    {:reply, frame, state}
  end

  @impl WebSockex
  def handle_disconnect(%{reason: reason}, state) do
    Logger.warning("FinnhubStream: disconnected — #{inspect(reason)}; reconnecting")

    {:reconnect, state}
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
