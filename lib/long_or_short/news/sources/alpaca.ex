defmodule LongOrShort.News.Sources.Alpaca do
  @moduledoc """
  Alpaca News API feeder (LON-128).

  Pulls Benzinga-sourced news from
  `https://data.alpaca.markets/v1beta1/news` in **firehose mode** —
  no `symbols=` filter on the request, so we receive the full
  market-wide stream. This matches the morning-brief workflow:
  trader wants to see *what's moving the market* (overnight
  catalysts, premarket headlines, opening movers), not just news
  already pre-filtered to a watchlist.

  Free for paper-trading accounts — see `env.example` for signup
  + key generation.

  Each Alpaca article tags one or more tickers in its `symbols`
  array; `parse_response/1` fans those out into one Article row
  per ticker. `News.ingest_article/2` auto-creates the Ticker row
  if it's not already in our universe (via
  `manage_relationship(:symbol, :ticker, on_no_match:
  {:create, :upsert_by_symbol})`), so the firehose grows the
  ticker DB naturally — Finnhub's `priv/tracked_tickers.txt`
  remains the polling whitelist for *its* per-symbol API, while
  this feeder is universe-agnostic.
  """

  use GenServer
  @behaviour LongOrShort.News.Source

  require Logger

  alias LongOrShort.News.Sources.Pipeline
  alias LongOrShort.Sources

  @base_url "https://data.alpaca.markets/v1beta1/news"

  # ── GenServer setup ────────────────────────────────────────────

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(opts), do: Pipeline.init(__MODULE__, opts)

  @impl GenServer
  def handle_info(:poll, state), do: Pipeline.run_poll(__MODULE__, state)

  # ── News.Source callbacks ──────────────────────────────────────

  @impl LongOrShort.News.Source
  def poll_interval_ms, do: 60_000

  @impl LongOrShort.News.Source
  def source_name, do: :alpaca

  @impl LongOrShort.News.Source
  def fetch_news(state) do
    key_id = Application.get_env(:long_or_short, :alpaca_api_key_id)
    secret = Application.get_env(:long_or_short, :alpaca_api_secret_key)

    if is_nil(key_id) or is_nil(secret) do
      {:error, :missing_credentials, state}
    else
      request(key_id, secret, state)
    end
  end

  @impl LongOrShort.News.Source
  def parse_response(raw) do
    with id when not is_nil(id) <- Map.get(raw, "id"),
         headline when is_binary(headline) <- Map.get(raw, "headline"),
         symbols when is_list(symbols) and symbols != [] <- Map.get(raw, "symbols", []),
         {:ok, published_at} <- parse_datetime(Map.get(raw, "created_at")) do
      attrs_list =
        for symbol when is_binary(symbol) and symbol != "" <- symbols do
          %{
            source: :alpaca,
            external_id: to_string(id),
            symbol: symbol,
            title: headline,
            summary: Map.get(raw, "summary"),
            url: Map.get(raw, "url"),
            # Alpaca's `source` field is the upstream vendor (e.g.
            # "Benzinga"). We surface it via `raw_category` so the
            # downstream consumers (NewsAnalysis, UI) can distinguish
            # vendor lineage without needing a new column.
            raw_category: Map.get(raw, "source"),
            sentiment: :unknown,
            published_at: published_at
          }
        end

      {:ok, attrs_list}
    else
      _ -> {:error, :missing_required_fields}
    end
  end

  # ── HTTP ───────────────────────────────────────────────────────

  defp request(key_id, secret, state) do
    headers = [
      {"APCA-API-KEY-ID", key_id},
      {"APCA-API-SECRET-KEY", secret}
    ]

    case Req.get(@base_url, params: build_params(), headers: headers) do
      {:ok, %{status: 200, body: %{"news" => items}}} when is_list(items) ->
        {:ok, items, state}

      {:ok, %{status: 200, body: body}} ->
        Logger.warning("Alpaca returned 200 but unexpected body shape: #{inspect(body)}")
        {:ok, [], state}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  # 60s overlap between cursor windows. Articles published in the
  # ~second between Pipeline's `update_source_state(:success)` call
  # and our next `start` cursor would otherwise be missed; the dedup
  # layer (per `source/external_id/symbol`) collapses the duplicates
  # this overlap creates. Trade-off: each poll re-fetches up to one
  # minute of already-seen articles, which is cheap.
  @cursor_overlap_seconds 60

  defp build_params do
    start =
      case Sources.get_source_state(:alpaca, authorize?: false) do
        {:ok, %{last_success_at: %DateTime{} = dt}} ->
          dt |> DateTime.add(-@cursor_overlap_seconds, :second) |> DateTime.to_iso8601()

        _ ->
          default_start()
      end

    # No `symbols=` parameter — Alpaca treats it as optional and
    # returns the full market-wide feed when omitted. That's the
    # whole point of this adapter (see module doc).
    [
      start: start,
      sort: "desc",
      limit: 50
    ]
  end

  defp default_start do
    DateTime.utc_now() |> DateTime.add(-3 * 86_400, :second) |> DateTime.to_iso8601()
  end

  defp parse_datetime(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, _} -> {:error, :invalid_datetime}
    end
  end

  defp parse_datetime(_), do: {:error, :missing_datetime}
end
