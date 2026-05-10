defmodule LongOrShort.Filings.BodyFetcher do
  @moduledoc """
  Fetches the primary document body for a stored `LongOrShort.Filings.Filing`
  from SEC EDGAR (LON-119, Stage 1b).

  Bridges Stage 1 (metadata-only feeder, LON-111) and Stage 3a
  (LLM extraction, LON-113) by populating `FilingRaw.raw_text` with
  cleaned plain text suitable for `LongOrShort.Filings.SectionFilter`.

  ## Pipeline

      Filing.url
        → accession directory (URI dirname)
        → GET <dir>/index.json
        → pick primary .htm document
        → GET <dir>/<primary>
        → HtmlText.to_text/1
        → SHA-256 of cleaned text
        → {:ok, text, hash}

  ## SEC EDGAR conventions

  Each filing's accession directory at
  `https://www.sec.gov/Archives/edgar/data/<cik>/<accession>/` contains:

    * `<accession>-index.htm` — the human index page (often Filing.url itself)
    * `index.json` — machine-readable directory listing
    * `<primary>.htm` — the actual filing document
    * `R1.htm`, `R2.htm`, ... — XBRL viewer files (skipped)
    * `ex_*.htm` — exhibits (skipped)

  The "primary" document is identified heuristically: the first `*.htm`
  file in the directory listing that is not an XBRL viewer (`R*`),
  not an exhibit (`ex_*`), and not the index page itself.

  ## HTTP

  Uses the same `:sec_user_agent` app env as the news / filings feeders
  (LON-111 / News.Sources.SecEdgar). Tests inject a Req plug via app
  config — see `LongOrShort.AI.Providers.Claude` for the same pattern.

  ## Error reasons

    * `:no_url` — Filing has no URL recorded
    * `:invalid_url` — URL is malformed (no parseable path)
    * `:no_primary_document` — index.json had no eligible `.htm` candidate
    * `:invalid_json` — index.json body wasn't valid JSON
    * `:empty_body` — fetched document produced no text after HTML→text
    * `{:http_status, status}` — non-200 response from SEC
    * `Req` transport errors propagate as-is
  """

  alias LongOrShort.Filings.{Filing, HtmlText}

  @receive_timeout :timer.seconds(60)

  @doc """
  Fetch and clean the body for a Filing.

  Returns `{:ok, raw_text, content_hash}` (where `content_hash` is the
  hex-encoded SHA-256 of `raw_text`) or `{:error, reason}`.
  """
  @spec fetch_body(Filing.t()) ::
          {:ok, String.t(), String.t()} | {:error, term()}
  def fetch_body(%Filing{url: nil}), do: {:error, :no_url}

  def fetch_body(%Filing{url: url}) when is_binary(url) do
    with {:ok, dir} <- accession_dir(url),
         {:ok, primary_url} <- find_primary_doc_url(dir),
         {:ok, html} <- http_get(primary_url),
         text = HtmlText.to_text(html),
         {:ok, text} <- non_empty(text) do
      {:ok, text, sha256(text)}
    end
  end

  # ── URL resolution ─────────────────────────────────────────────

  defp accession_dir(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, path: path}
      when is_binary(scheme) and is_binary(host) and is_binary(path) ->
        {:ok, "#{scheme}://#{host}#{Path.dirname(path)}"}

      _ ->
        {:error, :invalid_url}
    end
  end

  defp find_primary_doc_url(dir) do
    with {:ok, body} <- http_get(dir <> "/index.json"),
         {:ok, decoded} <- decode_json(body),
         {:ok, item} <- pick_primary(decoded) do
      {:ok, dir <> "/" <> item["name"]}
    end
  end

  defp pick_primary(decoded) do
    items = get_in(decoded, ["directory", "item"]) || []

    case Enum.find(items, &is_primary_doc?/1) do
      nil -> {:error, :no_primary_document}
      item -> {:ok, item}
    end
  end

  # Primary doc heuristic: an .htm that isn't an XBRL viewer (`R*`),
  # an exhibit (`ex_*`), or the index page (`*index*`).
  defp is_primary_doc?(%{"name" => name}) when is_binary(name) do
    String.ends_with?(name, ".htm") and
      not String.starts_with?(name, "R") and
      not String.contains?(name, "ex_") and
      not String.contains?(name, "index")
  end

  defp is_primary_doc?(_), do: false

  # ── HTTP ───────────────────────────────────────────────────────

  defp http_get(url) do
    user_agent = Application.fetch_env!(:long_or_short, :sec_user_agent)

    opts =
      [
        headers: [{"user-agent", user_agent}],
        receive_timeout: @receive_timeout,
        # Per-filing retry is handled by Oban (worker re-runs on next cron),
        # not by Req. Keep failures fast so per-filing failure doesn't drag
        # the whole cycle.
        retry: false
      ]
      |> maybe_add_test_plug()

    case Req.get(url, opts) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body_to_binary(body)}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_add_test_plug(opts) do
    case Application.get_env(:long_or_short, __MODULE__, [])[:req_plug] do
      nil -> opts
      plug -> Keyword.put(opts, :plug, plug)
    end
  end

  defp body_to_binary(body) when is_binary(body), do: body
  defp body_to_binary(body) when is_list(body), do: IO.iodata_to_binary(body)
  defp body_to_binary(body), do: body

  # ── Body parsing ───────────────────────────────────────────────

  # Req auto-decodes when content-type advertises JSON; SEC sometimes
  # serves index.json with `application/json` and sometimes plain
  # `text/plain`. Handle both shapes.
  defp decode_json(body) when is_map(body), do: {:ok, body}

  defp decode_json(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, map} -> {:ok, map}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  defp decode_json(_), do: {:error, :invalid_json}

  defp non_empty(""), do: {:error, :empty_body}
  defp non_empty(text), do: {:ok, text}

  defp sha256(text) do
    :sha256
    |> :crypto.hash(text)
    |> Base.encode16(case: :lower)
  end
end
