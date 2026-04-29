defmodule LongOrShort.News.Sources.SecEdgar do
  @moduledoc """
  SEC EDGAR 8-K filings feeder.

  Polls the SEC EDGAR Atom feed every 60 seconds for the latest 8-K
  filings, resolves CIK to ticker via the local mapping (LON-56),
  and ingests each entry as an Article.

  Filings whose CIK is not in our mapping (mutual funds, non-corporate
  filers, OTC stocks not in SEC's `company_tickers.json`) are dropped
  silently.

  ## SEC EDGAR rules

  - Required `User-Agent` header (`LongOrShort your@email.com` format)
  - Rate limit: 10 req/sec (60s polling is well under)
  """

  use GenServer
  @behaviour LongOrShort.News.Source

  require Logger
  import SweetXml

  alias LongOrShort.News.Sources.Pipeline
  alias LongOrShort.Tickers

  @feed_url "https://www.sec.gov/cgi-bin/browse-edgar?" <>
              "action=getcurrent&type=8-K&dateb=&owner=include&count=40&output=atom"

  # ── GenServer setup ──────────────────────────────────────────────
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(opts), do: Pipeline.init(__MODULE__, opts)

  @impl GenServer
  def handle_info(:poll, state), do: Pipeline.run_poll(__MODULE__, state)

  # ── News.Source callbacks ────────────────────────────────────────

  @impl LongOrShort.News.Source
  def source_name, do: :sec

  @impl LongOrShort.News.Source
  def poll_interval_ms, do: 60_000

  @impl LongOrShort.News.Source
  def fetch_news(state) do
    user_agent = Application.fetch_env!(:long_or_short, :sec_user_agent)

    case Req.get(@feed_url, headers: [{"user-agent", user_agent}]) do
      {:ok, %{status: 200, body: body}} ->
        entries = parse_entries(body)
        {:ok, entries, state}

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  @impl LongOrShort.News.Source
  def parse_response(entry) do
    with {:ok, cik} <- extract_cik(entry.title),
         {:ok, symbol} <- resolve_symbol(cik) do
      attrs = %{
        source: :sec,
        external_id: entry.id,
        symbol: symbol,
        title: entry.title,
        summary: clean_summary(entry.summary),
        url: entry.link,
        raw_category: entry.category,
        sentiment: :unknown,
        published_at: parse_datetime(entry.updated)
      }

      {:ok, [attrs]}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Atom parsing ─────────────────────────────────────────────────

  defp parse_entries(xml) do
    xml
    |> xpath(~x"//entry"l,
      title: ~x"./title/text()"s,
      link: ~x"./link/@href"s,
      summary: ~x"./summary/text()"s,
      updated: ~x"./updated/text()"s,
      category: ~x"./category/@term"s,
      id: ~x"./id/text()"s
    )
  end

  # ── Helpers ──────────────────────────────────────────────────────

  defp extract_cik(title) do
    case Regex.run(~r/\((\d{10})\)/, title) do
      [_, cik] -> {:ok, cik}
      _ -> {:error, :no_cik_in_title}
    end
  end

  defp resolve_symbol(cik) do
    case Tickers.get_ticker_by_cik(cik, authorize?: false) do
      {:ok, %{symbol: symbol}} ->
        {:ok, symbol}

      _ ->
        Logger.debug("SecEdgar: unmapped CIK #{cik}, skipping")
        {:error, :unmapped_cik}
    end
  end

  defp clean_summary(html) do
    html
    |> String.replace(~r/<br\s*\/?>/i, "\n")
    |> String.replace(~r/<[^>]+>/, "")
    |> String.trim()
  end

  defp parse_datetime(iso8601) do
    case DateTime.from_iso8601(iso8601) do
      {:ok, dt, _offset} -> dt
      _ -> DateTime.utc_now()
    end
  end
end
