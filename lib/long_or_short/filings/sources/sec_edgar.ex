defmodule LongOrShort.Filings.Sources.SecEdgar do
  @moduledoc """
  SEC EDGAR feeder for dilution-relevant regulatory filings.

  Polls the SEC EDGAR `getcurrent` Atom feed once per filing type
  per polling cycle (default 60s), resolves each filer's CIK to a
  local ticker via `LongOrShort.Tickers.get_ticker_by_cik/1`, and
  emits normalized filing attributes for the Pipeline's ingest sink.

  ## Filing types

  Configured via `:dilution_filing_types` app env (list of atoms).
  Each atom maps to an SEC form type via `@form_type_map`. The
  module makes one HTTP request per configured type per cycle —
  the filing type is tagged at fetch time rather than parsed from
  the Atom payload, so an entry's authoritative type matches the
  query that produced it.

  Filings whose CIK is not in our local ticker mapping are dropped
  silently (mutual funds, OTC tickers absent from
  `company_tickers.json`, etc.).

  ## SEC EDGAR rules

    * Required `User-Agent` header (`LongOrShort your@email.com`)
      via `:sec_user_agent` app env (shared with `News.Sources.SecEdgar`)
    * Rate limit: 10 req/sec — sequential per-type fetches with
      `@request_spacing_ms` gaps stay well under
  """

  use GenServer
  @behaviour LongOrShort.Filings.Source

  require Logger
  import SweetXml

  alias LongOrShort.Filings.Sources.Pipeline
  alias LongOrShort.Tickers

  @feed_base "https://www.sec.gov/cgi-bin/browse-edgar?" <>
               "action=getcurrent&owner=include&count=40&output=atom"

  # filing_type atom → SEC `type=` query string
  @form_type_map %{
    s1: "S-1",
    s1a: "S-1/A",
    s3: "S-3",
    s3a: "S-3/A",
    _424b1: "424B1",
    _424b2: "424B2",
    _424b3: "424B3",
    _424b4: "424B4",
    _424b5: "424B5",
    _8k: "8-K",
    _13d: "SC 13D",
    _13g: "SC 13G",
    def14a: "DEF 14A",
    form4: "4"
  }

  # Polite spacing between SEC requests within one polling cycle.
  # 150ms ≈ 6.7 req/s, comfortably under the 10 req/s ceiling.
  @request_spacing_ms 150

  @default_types Map.keys(@form_type_map)

  # ── GenServer setup ──────────────────────────────────────────────

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl GenServer
  def init(opts), do: Pipeline.init(__MODULE__, opts)

  @impl GenServer
  def handle_info(:poll, state), do: Pipeline.run_poll(__MODULE__, state)

  # ── Filings.Source callbacks ─────────────────────────────────────

  @impl LongOrShort.Filings.Source
  def source_name, do: :sec_filings

  @impl LongOrShort.Filings.Source
  def poll_interval_ms, do: 60_000

  @impl LongOrShort.Filings.Source
  def fetch_filings(state) do
    user_agent = Application.fetch_env!(:long_or_short, :sec_user_agent)
    types = configured_filing_types()

    {entries, errors} =
      types
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {filing_type, idx}, {ents, errs} ->
        if idx > 0, do: Process.sleep(@request_spacing_ms)

        case fetch_one_type(filing_type, user_agent) do
          {:ok, type_entries} -> {ents ++ type_entries, errs}
          {:error, reason} -> {ents, [{filing_type, reason} | errs]}
        end
      end)

    classify_fetch_outcome(entries, errors, types, state)
  end

  @impl LongOrShort.Filings.Source
  def parse_response(entry) do
    with {:ok, cik} <- extract_cik(entry.title),
         {:ok, symbol} <- resolve_symbol(cik) do
      attrs = %{
        source: :sec_edgar,
        filing_type: entry.filing_type,
        filing_subtype: extract_subtype(entry),
        external_id: entry.id,
        symbol: symbol,
        filer_cik: cik,
        filed_at: parse_datetime(entry.updated),
        url: entry.link
      }

      {:ok, [attrs]}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Internal: fetch / parse ──────────────────────────────────────

  defp configured_filing_types do
    Application.get_env(:long_or_short, :dilution_filing_types, @default_types)
  end

  defp fetch_one_type(filing_type, user_agent) do
    case Map.fetch(@form_type_map, filing_type) do
      {:ok, form_name} ->
        url = @feed_base <> "&type=" <> URI.encode_www_form(form_name)
        do_http_get(url, filing_type, user_agent)

      :error ->
        {:error, {:unknown_filing_type, filing_type}}
    end
  end

  defp do_http_get(url, filing_type, user_agent) do
    case Req.get(url, headers: [{"user-agent", user_agent}]) do
      {:ok, %{status: 200, body: body}} ->
        entries =
          body
          |> parse_entries()
          |> Enum.map(&Map.put(&1, :filing_type, filing_type))

        {:ok, entries}

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp classify_fetch_outcome(entries, [], _types, state), do: {:ok, entries, state}

  defp classify_fetch_outcome(entries, errors, types, state) do
    if length(errors) == length(types) do
      {:error, {:all_filing_types_failed, errors}, state}
    else
      Logger.warning(
        "Filings.Sources.SecEdgar: partial fetch failure " <>
          "(#{length(errors)}/#{length(types)} types) — #{inspect(errors)}"
      )

      {:ok, entries, state}
    end
  end

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

  # ── Internal: helpers ────────────────────────────────────────────

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
        Logger.debug("Filings.Sources.SecEdgar: unmapped CIK #{cik}, skipping")
        {:error, :unmapped_cik}
    end
  end

  # 8-K Item subtype lives in the summary's HTML body. Phase 1
  # extracts the first matching `Item N.NN` and stores it as a
  # human-readable string (e.g. "Item 3.02"). Stage 3 may refine.
  defp extract_subtype(%{filing_type: :_8k, summary: summary}) when is_binary(summary) do
    case Regex.run(~r/Item\s+(\d+\.\d+)/, summary) do
      [_, item] -> "Item #{item}"
      _ -> nil
    end
  end

  defp extract_subtype(_entry), do: nil

  defp parse_datetime(iso8601) do
    case DateTime.from_iso8601(iso8601) do
      {:ok, dt, _offset} -> dt
      _ -> DateTime.utc_now()
    end
  end
end
