defmodule LongOrShort.News.Sources.Finnhub do
  @moduledoc """
  Finnhub company-news feeder.

  Polls `/api/v1/company-news` for each ticker in the configured
  watchlist every 60 seconds (free tier: 60 calls/min).

  Tickers are configured via `:finnhub_watch_symbols`:

      config :long_or_short, :finnhub_watch_symbols, ~w(BTBD AAPL TSLA NVDA AMD)

  Each poll fetches the last 3 days of news per ticker.
  `related` field is a single ticker string — no splitting needed.

  ## ⚠️ Temporary config — replace before LON-36

  The symbol list is currently read from application config
  (`:finnhub_watch_symbols`) as a temporary measure for pipeline
  validation. This must be replaced with a DB-based watchlist before
  LON-36 ships:

      # Replace this:
      Application.get_env(:long_or_short, :finnhub_watch_symbols, @default_symbols)

      # With this (LON-36):
      LongOrShort.Tickers.list_active_tickers() |> Enum.map(& &1.symbol)

  See LON-36 for the full watchlist feature design.
  """

  use GenServer
  @behaviour LongOrShort.News.Source

  alias LongOrShort.News.Sources.Pipeline

  @base_url "https://finnhub.io/api/v1/company-news"
  @default_symbols ~w(BTBD AAPL TSLA NVDA AMD)

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
  def fetch_news(state) do
    api_key = Application.get_env(:long_or_short, :finnhub_api_key)
    symbols = Application.get_env(:long_or_short, :finnhub_watch_symbols, @default_symbols)

    from =
      case LongOrShort.Sources.get_source_state(:finnhub, authorize?: false) do
        {:ok, %{last_success_at: %DateTime{} = dt}} -> DateTime.to_date(dt)
        _ -> Date.add(Date.utc_today(), -3)
      end

    to = Date.utc_today()

    results =
      Enum.flat_map(symbols, fn symbol ->
        case Req.get(@base_url,
               params: [
                 symbol: symbol,
                 from: Date.to_string(from),
                 to: Date.to_string(to),
                 token: api_key
               ]
             ) do
          {:ok, %{status: 200, body: items}} when is_list(items) ->
            items

          {:ok, %{status: status}} ->
            require Logger
            Logger.warning("Finnhub API returned #{status} for #{symbol}")
            []

          {:error, reason} ->
            require Logger
            Logger.warning("Finnhub API error for #{symbol}: #{inspect(reason)}")
            []
        end
      end)

    {:ok, results, state}
  end

  @impl LongOrShort.News.Source
  def parse_response(raw) do
    with symbol when is_binary(symbol) and symbol != "" <- Map.get(raw, "related"),
         id when not is_nil(id) <- Map.get(raw, "id"),
         headline when is_binary(headline) <- Map.get(raw, "headline") do
      attrs = %{
        source: :finnhub,
        external_id: to_string(id),
        symbol: symbol,
        title: headline,
        summary: Map.get(raw, "summary"),
        url: Map.get(raw, "url"),
        raw_category: Map.get(raw, "category"),
        sentiment: :unknown,
        published_at: parse_datetime(Map.get(raw, "datetime"))
      }

      {:ok, [attrs]}
    else
      _ -> {:error, :missing_required_fields}
    end
  end

  @impl LongOrShort.News.Source
  def source_name, do: :finnhub

  # ── Helpers ────────────────────────────────────────────────────

  defp parse_datetime(unix) when is_integer(unix) do
    DateTime.from_unix!(unix)
  end

  defp parse_datetime(_), do: DateTime.utc_now()
end
