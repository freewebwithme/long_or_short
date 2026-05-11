defmodule LongOrShort.Filings.Workers.Form4Worker do
  @moduledoc """
  Oban worker that processes Form 4 filings — fetches the
  ownership XML, parses it via `LongOrShort.Filings.Form4Parser`,
  and persists each `<nonDerivativeTransaction>` as a
  `LongOrShort.Filings.InsiderTransaction` row. LON-118, Stage 9.

  ## Why not reuse `FilingBodyFetcher`

  `FilingBodyFetcher` (LON-119) fetches the **HTML** body and runs
  it through `HtmlText.to_text/1`, populating `FilingRaw.raw_text`
  for the LLM extraction pipeline. Form 4 is structured XML —
  HTML-to-text destroys the structure we need, and running LLM
  extraction on Form 4 would be both wasteful and less accurate
  than direct XML parsing. So Form 4 takes a parallel path:

    1. `FilingBodyFetcher` skips Form 4 (filtered out at query level).
    2. This worker discovers the XML in the accession directory
       and fetches it raw.
    3. `Form4Parser` turns it into transaction maps.
    4. Each map becomes one `InsiderTransaction` row.

  ## Idempotency

  Two layers:

    * Query — `insider_transaction_count == 0` (aggregate on
      `Filing`) skips filings that already have transactions, so
      re-running is cheap.
    * Transaction wrap — each filing's batch insert runs in a DB
      transaction. Either every row lands or none do; partial state
      is impossible. On error the worker re-discovers the filing
      on the next cycle.

  ### Edge case: Form 4 with zero `<nonDerivativeTransaction>` rows

  Some Form 4 filings carry only derivative transactions (option
  grants, conversions) — Phase 1 skips derivative rows
  (see `Form4Parser` moduledoc). For those filings, parsing yields
  an empty list and no rows get inserted. The worker still treats
  the filing as processed for telemetry purposes, but the query
  will re-pick it next cycle (still `insider_transaction_count == 0`).

  The cost is one HTTP fetch + one parse per zero-transaction
  filing per cycle. Acceptable for Phase 1 — these filings are a
  small minority. If they accumulate enough to matter in
  production, swap to a `Filing.form4_processed_at` timestamp.

  ## Schedule

  Cron-driven, every 15 minutes (same cadence as
  `FilingBodyFetcher` / `FilingAnalysisWorker`). Picks up to
  `@batch_size` of the oldest pending filings.

  ## Rate limiting

  150 ms gap between filings (mirrors SEC EDGAR feeder convention),
  one HTTP request per filing pair (index.json + XML), so a
  50-filing batch is ~15 s of SEC traffic — well under the 10 req/s
  ceiling.

  ## Telemetry

  Emits `[:long_or_short, :form4_worker, :complete]` once per cycle
  with `%{ok: n, error: n, total: n}`.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Ash.Query
  require Logger

  alias LongOrShort.Accounts.SystemActor
  alias LongOrShort.Filings
  alias LongOrShort.Filings.{Filing, Form4Parser}
  alias LongOrShort.Repo

  @batch_size 50
  @per_filing_pause_ms 150
  @receive_timeout :timer.seconds(60)

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    pending = find_pending_form4(@batch_size)
    total = length(pending)

    if total == 0 do
      Logger.debug("Form4Worker: no pending Form 4 filings")
      :ok
    else
      run_batch(pending, total)
    end
  end

  defp run_batch(filings, total) do
    Logger.info("Form4Worker: processing #{total} pending Form 4 filings")

    {ok_count, err_count} =
      filings
      |> Enum.with_index()
      |> Enum.reduce({0, 0}, fn {filing, idx}, {ok, err} ->
        if idx > 0, do: Process.sleep(@per_filing_pause_ms)

        case process_one(filing) do
          :ok -> {ok + 1, err}
          {:error, _} -> {ok, err + 1}
        end
      end)

    Logger.info("Form4Worker: complete — #{ok_count} ok, #{err_count} failed")

    :telemetry.execute(
      [:long_or_short, :form4_worker, :complete],
      %{ok: ok_count, error: err_count, total: total},
      %{}
    )

    :ok
  end

  defp find_pending_form4(limit) do
    Filing
    |> Ash.Query.filter(filing_type == :form4 and insider_transaction_count == 0)
    |> Ash.Query.sort(filed_at: :asc)
    |> Ash.Query.limit(limit)
    |> Ash.read!(actor: SystemActor.new())
  end

  defp process_one(filing) do
    with {:ok, xml_body} <- fetch_xml(filing),
         {:ok, transactions} <- Form4Parser.parse(xml_body),
         :ok <- persist_transactions(filing, transactions) do
      :ok
    else
      {:error, reason} ->
        Logger.warning(
          "Form4Worker: #{inspect(reason)} for filing #{filing.id} (url=#{filing.url})"
        )

        {:error, reason}
    end
  end

  # ── XML fetching ─────────────────────────────────────────────────

  # Mirrors `LongOrShort.Filings.BodyFetcher`'s URL handling but
  # picks the first `.xml` instead of the first `.htm`. Keeping it
  # inline rather than refactoring the shared logic out of
  # BodyFetcher — the two have meaningfully different downstream
  # processing (text vs raw XML, single doc vs N transactions) and
  # premature extraction would force a less natural API.
  defp fetch_xml(%Filing{url: nil}), do: {:error, :no_url}

  defp fetch_xml(%Filing{url: url}) do
    with {:ok, dir} <- accession_dir(url),
         {:ok, listing} <- fetch_index_json(dir),
         {:ok, xml_name} <- pick_xml(listing) do
      fetch_document(dir, xml_name)
    end
  end

  defp accession_dir(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, path: path}
      when is_binary(scheme) and is_binary(host) and is_binary(path) ->
        {:ok, "#{scheme}://#{host}#{Path.dirname(path)}/"}

      _ ->
        {:error, :invalid_url}
    end
  end

  defp fetch_index_json(dir) do
    case Req.get(req_client(), url: dir <> "index.json") do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        case get_in(body, ["directory", "item"]) do
          items when is_list(items) -> {:ok, items}
          _ -> {:error, :invalid_json}
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, {:network_error, reason}}

      {:error, reason} ->
        {:error, {:network_error, reason}}
    end
  end

  # Form 4 accession dirs typically contain one ownership XML named
  # `wf-form4_*.xml` (the rendered version) or just `<accession>.xml`.
  # Pick the first `.xml` regardless of name — SEC's directory
  # contents follow a stable convention but we don't rely on the
  # name format. Skip XSD schemas (`*.xsd`) and any exhibits.
  defp pick_xml(items) do
    xml =
      Enum.find_value(items, fn
        %{"name" => name} when is_binary(name) ->
          cond do
            String.ends_with?(name, ".xsd") -> nil
            String.ends_with?(name, ".xml") -> name
            true -> nil
          end

        _ ->
          nil
      end)

    case xml do
      nil -> {:error, :no_xml_document}
      name -> {:ok, name}
    end
  end

  defp fetch_document(dir, name) do
    case Req.get(req_client(), url: dir <> name) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, {:network_error, reason}}

      {:error, reason} ->
        {:error, {:network_error, reason}}
    end
  end

  defp req_client do
    base =
      Req.new(
        headers: [
          {"user-agent", Application.fetch_env!(:long_or_short, :sec_user_agent)},
          {"accept", "application/json, application/xml, */*"}
        ],
        receive_timeout: @receive_timeout,
        retry: false
      )

    case Application.get_env(:long_or_short, :form4_worker_req_plug) do
      nil -> base
      plug -> Req.merge(base, plug: plug)
    end
  end

  # ── Persistence ──────────────────────────────────────────────────

  defp persist_transactions(_filing, []), do: :ok

  defp persist_transactions(filing, transactions) do
    actor = SystemActor.new()

    Repo.transaction(fn ->
      Enum.each(transactions, fn t ->
        attrs =
          t
          |> Map.put(:filing_id, filing.id)
          |> Map.put(:ticker_id, filing.ticker_id)

        case Filings.create_insider_transaction(attrs, actor: actor) do
          {:ok, _row} -> :ok
          {:error, reason} -> Repo.rollback({:create_failed, reason})
        end
      end)
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
