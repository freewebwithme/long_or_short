defmodule LongOrShort.Tickers.Sources.IwmHoldings do
  @moduledoc """
  Fetches and parses the iShares Russell 2000 ETF (IWM) holdings CSV
  (LON-133). Output drives the small-cap universe used by the Tier 1
  filing extractor (LON-135).

  ## CSV shape

  iShares publishes daily holdings as a UTF-8 CSV with a 9-line
  metadata header (fund name, NAV date, share/cash breakdown, blank
  separator) followed by a column-header row beginning with
  `Ticker,Name,Sector,Asset Class,...`, then ~1,900 holdings rows,
  then a footer disclaimer.

  Parsing strategy:

    1. Strip a UTF-8 BOM if present.
    2. Scan for the `Ticker,Name,Sector` header line — robust to
       iShares changing the metadata row count.
    3. NimbleCSV parse from the header onward.
    4. Drop rows whose column count or asset class doesn't look like
       a holdings row. This filters both non-equity (Cash, Money
       Market, Futures) and the trailing disclaimer text.

  ## URL stability

  iShares' file ID (`1467271812596`) has been stable for years but is
  unversioned. If the URL ever 404s, the fallback is to scrape the
  fund product page (`/us/products/239710/...`) for the current file
  ID. Not implemented here — keep it simple until it breaks.
  """

  require Logger

  NimbleCSV.define(__MODULE__.Parser, separator: ",", escape: "\"")

  @default_url "https://www.ishares.com/us/products/239710/ishares-russell-2000-etf/" <>
                 "1467271812596.ajax?fileType=csv&fileName=IWM_holdings&dataType=fund"

  @bom "﻿"
  @header_prefix "Ticker,Name,Sector"
  @expected_columns 15

  @type holding :: %{
          symbol: String.t(),
          name: String.t() | nil,
          sector: String.t() | nil,
          exchange: :nasdaq | :nyse | :amex | :otc | :other
        }

  @doc """
  Fetch + parse in one call. Returns the holdings list or an error.
  """
  @spec fetch_and_parse() :: {:ok, [holding]} | {:error, term()}
  def fetch_and_parse do
    with {:ok, csv} <- fetch_holdings() do
      parse_holdings(csv)
    end
  end

  @doc """
  Download the raw IWM holdings CSV. URL is overridable via
  `:iwm_holdings_url` app env (used by tests).
  """
  @spec fetch_holdings() :: {:ok, binary()} | {:error, term()}
  def fetch_holdings do
    url = Application.get_env(:long_or_short, :iwm_holdings_url, @default_url)
    user_agent = Application.fetch_env!(:long_or_short, :sec_user_agent)

    case Req.get(url, headers: [{"user-agent", user_agent}]) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Parse a raw IWM holdings CSV binary into structured holdings.

  Returns `{:error, :header_not_found}` if the `Ticker,Name,Sector...`
  row is missing — usually means iShares changed format and we should
  notice.
  """
  @spec parse_holdings(binary()) :: {:ok, [holding]} | {:error, term()}
  def parse_holdings(csv) when is_binary(csv) do
    with {:ok, sliced} <- slice_from_header(csv) do
      holdings =
        sliced
        |> __MODULE__.Parser.parse_string(skip_headers: true)
        |> Enum.flat_map(&row_to_holding/1)

      {:ok, holdings}
    end
  end

  defp slice_from_header(csv) do
    csv
    |> String.replace_prefix(@bom, "")
    |> String.split(~r/\r?\n/)
    |> Enum.drop_while(&(not String.starts_with?(&1, @header_prefix)))
    |> case do
      [] -> {:error, :header_not_found}
      lines -> {:ok, Enum.join(lines, "\n")}
    end
  end

  defp row_to_holding(row) when length(row) == @expected_columns do
    [
      ticker,
      name,
      sector,
      asset_class,
      _market_value,
      _weight,
      _notional,
      _quantity,
      _price,
      _location,
      exchange | _rest
    ] = row

    if asset_class == "Equity" do
      [
        %{
          symbol: ticker |> String.trim() |> String.upcase(),
          name: blank_to_nil(name),
          sector: blank_to_nil(sector),
          exchange: parse_exchange(exchange)
        }
      ]
    else
      []
    end
  end

  defp row_to_holding(_), do: []

  defp blank_to_nil(""), do: nil
  defp blank_to_nil("-"), do: nil
  defp blank_to_nil(s) when is_binary(s), do: s
  defp blank_to_nil(_), do: nil

  defp parse_exchange(string) when is_binary(string) do
    upcased = String.upcase(string)

    cond do
      String.contains?(upcased, "NASDAQ") -> :nasdaq
      String.contains?(upcased, "NYSE ARCA") -> :nyse
      String.contains?(upcased, "NYSE AMERICAN") -> :amex
      String.contains?(upcased, "AMEX") -> :amex
      String.contains?(upcased, "NYSE") -> :nyse
      String.contains?(upcased, "CBOE") -> :other
      String.contains?(upcased, "BATS") -> :other
      true -> :other
    end
  end

  defp parse_exchange(_), do: :other
end
