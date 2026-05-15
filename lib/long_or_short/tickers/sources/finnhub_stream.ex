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

  ## Reconnect policy (LON-67)

  `handle_disconnect/2` buckets the disconnect reason into `:transient`
  or `:persistent` via `classify_reason/1`.

    * `:transient` (`{:remote, _}`, `:tcp_closed`, `502`, generic network
      errors) — sleep for `backoff_ms(attempt)` (1s, 2s, 4s, 8s, 16s,
      capped at 30s) and reconnect. After `@max_attempts` consecutive
      failures, give up and let the supervisor decide.
    * `:persistent` (`429 Too Many Requests`, `401`/`403` upgrade
      failures, auth-related close codes) — stop immediately. Reconnecting
      on a `429` *is* what triggered the abuse-policy throttling in the
      first place; the supervisor's restart budget is the right hammer.

  `terminate/2` makes a best-effort attempt to send `unsubscribe` frames
  for every active symbol plus a WebSocket close frame before exiting,
  so app shutdown / code reload doesn't leave a zombie connection that
  conflicts with the post-restart instance (Finnhub free tier only
  allows one connection per token).

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

  # LON-67 — backoff schedule for transient disconnects.
  # 1s, 2s, 4s, 8s, 16s, then capped at @max_backoff_ms.
  @max_attempts 5
  @max_backoff_ms 30_000

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
  def handle_connect(conn, state) do
    WatchlistEvents.subscribe_any()
    desired = compute_subscription_set()

    Logger.info(
      "FinnhubStream: connected, subscribing to #{length(desired)} symbols"
    )

    # LON-67 — emit :reconnected if we were previously disconnected so
    # dashboards can compute reconnect rate. The very first connect
    # (state was just-built with connected?: false) also counts as a
    # reconnect-from-nothing; that's fine — the metric is "transitions
    # into connected," not "post-failure recoveries."
    :telemetry.execute(
      [:long_or_short, :finnhub_stream, :reconnected],
      %{symbol_count: length(desired)},
      %{}
    )

    send(self(), {:subscribe_next, desired})

    {:ok,
     state
     |> Map.put(:subscribed, MapSet.new(desired))
     |> Map.put(:connected?, true)
     |> Map.put(:conn, conn)}
  end

  @impl WebSockex
  def handle_disconnect(%{reason: reason, attempt_number: attempt}, state) do
    bucket = classify_reason(reason)

    :telemetry.execute(
      [:long_or_short, :finnhub_stream, :disconnected],
      %{attempt: attempt},
      %{reason_bucket: bucket, reason: inspect(reason)}
    )

    new_state = %{state | subscribed: MapSet.new(), connected?: false}

    case {bucket, attempt} do
      {:persistent, _} ->
        Logger.error(
          "FinnhubStream: persistent disconnect — #{inspect(reason)} " <>
            "(attempt #{attempt}); not reconnecting, supervisor will decide"
        )

        {:ok, new_state}

      {:transient, n} when n >= @max_attempts ->
        Logger.error(
          "FinnhubStream: gave up after #{n} transient reconnect attempts; " <>
            "last reason #{inspect(reason)}"
        )

        {:ok, new_state}

      {:transient, n} ->
        delay = backoff_ms(n)

        Logger.warning(
          "FinnhubStream: transient disconnect — #{inspect(reason)} " <>
            "(attempt #{n}); reconnecting in #{delay}ms"
        )

        Process.sleep(delay)
        {:reconnect, new_state}
    end
  end

  @impl WebSockex
  def terminate(reason, state) do
    Logger.info("FinnhubStream: terminating — #{inspect(reason)}; closing connection")
    send_graceful_close(state)
    :ok
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

  # ── LON-67 lifecycle helpers ─────────────────────────────────────

  @doc """
  Buckets a WebSockex disconnect reason into `:transient` (network
  blip — retry with backoff) or `:persistent` (abuse-policy / auth —
  stop and let the supervisor decide).

  Persistent reasons that have been observed empirically:

    * `%WebSockex.RequestError{code: 429}` — abuse policy throttling.
      Reconnecting is precisely what triggers further `429`s.
    * `%WebSockex.RequestError{code: 401 | 403}` — auth failure
      (bad/expired token). No point retrying.

  Anything else is treated as transient. Pure. Public for testing.
  """
  @spec classify_reason(term()) :: :transient | :persistent
  def classify_reason(%WebSockex.RequestError{code: code}) when code in [401, 403, 429],
    do: :persistent

  def classify_reason(_), do: :transient

  @doc """
  Exponential backoff schedule for transient reconnect attempts:
  1s, 2s, 4s, 8s, 16s, then capped at `@max_backoff_ms` (30s).
  Pure. Public for testing.
  """
  @spec backoff_ms(non_neg_integer()) :: non_neg_integer()
  def backoff_ms(attempt) when attempt >= 1 do
    base = :math.pow(2, attempt - 1) |> trunc()
    min(base * 1_000, @max_backoff_ms)
  end

  def backoff_ms(_), do: 1_000

  # Best-effort graceful close. Sends unsubscribe text frames for
  # every active symbol and then a close frame on the way out. We
  # can't use `WebSockex.send_frame/2` here because it would `gen.call`
  # ourselves and deadlock — instead we encode frames manually and
  # write them to the socket directly via `WebSockex.Conn.socket_send/2`.
  defp send_graceful_close(%{conn: %WebSockex.Conn{} = conn, connected?: true} = state) do
    state.subscribed
    |> Enum.each(fn symbol ->
      payload = Jason.encode!(%{type: "unsubscribe", symbol: symbol})
      _ = encode_and_send(conn, {:text, payload})
    end)

    _ = encode_and_send(conn, :close)
    _ = WebSockex.Conn.close_socket(conn)
    :ok
  end

  defp send_graceful_close(_state), do: :ok

  defp encode_and_send(conn, frame) do
    try do
      with {:ok, bytes} <- WebSockex.Frame.encode_frame(frame),
           :ok <- WebSockex.Conn.socket_send(conn, bytes) do
        :ok
      else
        _ -> :error
      end
    rescue
      _ -> :error
    catch
      _, _ -> :error
    end
  end
end
