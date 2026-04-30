defmodule LongOrShort.Tickers.Workers.FinnhubProfileSync do
  @moduledoc """
  Daily Oban Cron worker that enriches `LongOrShort.Tickers.Ticker`
  rows from Finnhub's `/stock/profile2` endpoint.

  ## Field mapping (free tier)

      Ticker field         | Finnhub field             | Notes
      -------------------- | ------------------------- | -----
      :company_name        | "name"                    | overwrites SEC value
      :exchange            | "exchange"                | mapped to enum
                                                         (:nasdaq | :nyse |
                                                         :amex | :otc | :other)
      :industry            | "finnhubIndustry"         | free-tier string
      :sector              | (not on free tier)        | left nil for MVP
      :shares_outstanding  | "shareOutstanding" × 1M   | API returns millions
      :float_shares        | "shareOutstanding" × 1M   | MVP proxy — free tier
                                                         does not expose
                                                         freeFloat. Follow-up
                                                         ticket will add FMP
                                                         for accurate float.

  ## Cadence

  Daily, registered via `Oban.Plugins.Cron`. Active-ticker counts are
  small for the MVP, comfortably within the free-tier 60 req/min budget;
  we run serially with a small pause between calls.

  ## Robustness

  Per-symbol failures (HTTP, parse, validation) are logged and counted
  but never abort the cycle.
  """

  use Oban.Worker, queue: :default, max_attempts: 3
  require Logger

  alias LongOrShort.Tickers

  @endpoint "https://finnhub.io/api/v1/stock/profile2"
  @per_symbol_pause_ms 1_200

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case Application.get_env(:long_or_short, :finnhub_api_key) do
      key when is_binary(key) and key != "" ->
        run_sync(key)

      _ ->
        Logger.warning("FinnhubProfileSync: skipping - no API key configured")
        :ok
    end
  end

  defp run_sync(api_key) do
    {:ok, tickers} = Tickers.list_active_tickers(authorize?: false)
    total = length(tickers)

    Logger.info("FinnhubProfileSync: starting sync for #{total} tickers")

    {ok_count, err_count} =
      tickers
      |> Enum.with_index()
      |> Enum.reduce({0, 0}, fn {ticker, idx}, {ok, err} ->
        if idx > 0, do: Process.sleep(@per_symbol_pause_ms)

        case sync_one(ticker, api_key) do
          :ok -> {ok + 1, err}
          {:error, _} -> {ok, err + 1}
        end
      end)

    Logger.info(
      "FinnhubProfileSync: complete — #{ok_count} ok, #{err_count} failed " <>
        "(#{total} total)"
    )

    :telemetry.execute(
      [:long_or_short, :finnhub_profile_sync, :complete],
      %{ok: ok_count, error: err_count, total: total},
      %{}
    )

    :ok
  end

  defp sync_one(ticker, api_key) do
    with {:ok, payload} <- fetch_profile(ticker.symbol, api_key),
         attrs = build_attrs(ticker.symbol, payload),
         {:ok, _} <- Tickers.upsert_ticker_by_symbol(attrs, authorize?: false) do
      :ok
    else
      {:error, reason} = err ->
        Logger.warning("FinnhubProfileSync: #{ticker.symbol} failed — #{inspect(reason)}")
        err
    end
  end

  # Public for tests — pure transformation, no I/O.
  @doc false
  def build_attrs(symbol, payload) when is_binary(symbol) and is_map(payload) do
    %{
      symbol: symbol,
      company_name: payload["name"],
      exchange: parse_exchange(payload["exchange"]),
      industry: payload["finnhubIndustry"],
      shares_outstanding: parse_share_count(payload["shareOutstanding"]),
      float_shares: parse_share_count(payload["shareOutstanding"])
    }
  end

  defp fetch_profile(symbol, api_key) do
    case Req.get(@endpoint, params: [symbol: symbol, token: api_key]) do
      {:ok, %{status: 200, body: body}} when is_map(body) and map_size(body) > 0 ->
        {:ok, body}

      {:ok, %{status: 200}} ->
        {:error, :empty_response}

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # `/stock/profile2` returns shares in millions (e.g. 16_350.34 → 16.35B).
  defp parse_share_count(n) when is_number(n) and n > 0, do: trunc(n * 1_000_000)
  defp parse_share_count(_), do: nil

  defp parse_exchange(string) when is_binary(string) do
    cond do
      String.contains?(string, "NASDAQ") -> :nasdaq
      String.contains?(string, "NEW YORK STOCK EXCHANGE") -> :nyse
      String.contains?(string, "NYSE ARCA") -> :nyse
      String.contains?(string, "AMEX") -> :amex
      String.contains?(string, "OTC") -> :otc
      true -> :other
    end
  end

  defp parse_exchange(_), do: nil
end
