defmodule LongOrShort.Tickers.Sources.IndicesPoller do
  @moduledoc """
  Polls Finnhub /quote every 30s for ETF proxies of the major US indices
  (DIA → DJIA, QQQ → NASDAQ-100, SPY → S&P 500) and broadcasts ticks
  on the "indices" PubSub topic.
  """

  use GenServer
  require Logger

  alias LongOrShort.Indices.Events

  @endpoint "https://finnhub.io/api/v1/quote"
  @poll_ms 30_000

  @indices [
    {"DJIA", "DIA"},
    {"NASDAQ-100", "QQQ"},
    {"S&P 500", "SPY"}
  ]

  def indices, do: @indices

  def start_link(_opts) do
    case Application.get_env(:long_or_short, :finnhub_api_key) do
      key when is_binary(key) and key != "" ->
        GenServer.start_link(__MODULE__, key, name: __MODULE__)

      _ ->
        Logger.info("IndicePoller: no API key - not starting")
        :ignore
    end
  end

  @impl GenServer
  def init(api_key) do
    send(self(), :poll)
    {:ok, %{api_key: api_key}}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    Process.send_after(self(), :poll, @poll_ms)
    fetch_and_broadcast(state.api_key)
    {:noreply, state}
  end

  @doc false
  def fetch_and_broadcast(api_key) do
    Enum.each(@indices, fn {label, symbol} ->
      case fetch_quote(symbol, api_key) do
        {:ok, body} ->
          Events.broadcast(label, build_payload(symbol, body))

        {:error, reason} ->
          Logger.warning("IndicesPoller: #{symbol} failed - #{inspect(reason)}")
      end
    end)
  end

  @doc false
  def build_payload(symbol, body) do
    %{
      current: to_decimal(body["c"]),
      change_pct: to_decimal(body["dp"]),
      prev_close: to_decimal(body["pc"]),
      symbol: symbol,
      fetched_at: DateTime.utc_now()
    }
  end

  defp fetch_quote(symbol, api_key) do
    case Req.get(@endpoint, params: [symbol: symbol, token: api_key]) do
      {:ok, %{status: 200, body: %{"c" => c} = body}} when is_number(c) and c > 0 ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp to_decimal(n) when is_number(n), do: Decimal.new(to_string(n))
  defp to_decimal(_), do: Decimal.new(0)
end
