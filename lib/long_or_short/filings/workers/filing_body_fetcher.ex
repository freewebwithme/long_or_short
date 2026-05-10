defmodule LongOrShort.Filings.Workers.FilingBodyFetcher do
  @moduledoc """
  Oban worker that fetches SEC filing bodies and populates `FilingRaw`
  rows (LON-119, Stage 1b).

  Bridges Stage 1's metadata-only feeder (LON-111) and Stage 3a's LLM
  extraction (LON-113) by ensuring every Filing has a body to extract
  from.

  ## Schedule

  Cron-driven, every 15 minutes. Picks up to `@batch_size` of the
  oldest Filings lacking a FilingRaw and processes them via
  `LongOrShort.Filings.BodyFetcher.fetch_body/1` →
  `LongOrShort.Filings.create_filing_raw/2`.

  ## Idempotency

  Two layers:

    * Query — `is_nil(filing_raw)` skips Filings that already have a
      body persisted, so re-running is cheap.
    * DB — `FilingRaw`'s `:unique_filing` identity on `:filing_id`
      enforces one body row per Filing at the row level.

  ## Rate limiting

  150 ms gap between Filings (mirroring `Filings.Sources.SecEdgar`'s
  `@request_spacing_ms`). Each Filing makes two SEC requests
  (`index.json` + primary document), so a 100-Filing batch is roughly
  30 s of HTTP work — comfortably under SEC's 10 req/s ceiling at
  ~6.7 effective req/s.

  ## Failure handling

  Per-Filing fetch errors are logged + counted but never abort the
  cycle — the next cron run picks up the same Filing (still no
  FilingRaw) and retries. Oban's `max_attempts: 3` handles cycle-wide
  errors (DB outage, etc.).

  ## Telemetry

  Emits `[:long_or_short, :filing_body_fetcher, :complete]` once per
  cycle with `%{ok: count, error: count, total: count}`.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Ash.Query
  require Logger

  alias LongOrShort.Accounts.SystemActor
  alias LongOrShort.Filings
  alias LongOrShort.Filings.{BodyFetcher, Filing}

  @batch_size 100
  @per_filing_pause_ms 150

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    pending = find_pending_filings(@batch_size)
    total = length(pending)

    if total == 0 do
      Logger.debug("FilingBodyFetcher: no pending filings")
      :ok
    else
      run_batch(pending, total)
    end
  end

  defp run_batch(filings, total) do
    Logger.info("FilingBodyFetcher: processing #{total} pending filings")

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

    Logger.info("FilingBodyFetcher: complete — #{ok_count} ok, #{err_count} failed")

    :telemetry.execute(
      [:long_or_short, :filing_body_fetcher, :complete],
      %{ok: ok_count, error: err_count, total: total},
      %{}
    )

    :ok
  end

  defp find_pending_filings(limit) do
    Filing
    |> Ash.Query.filter(is_nil(filing_raw))
    |> Ash.Query.sort(filed_at: :asc)
    |> Ash.Query.limit(limit)
    |> Ash.read!(actor: SystemActor.new())
  end

  defp process_one(filing) do
    case BodyFetcher.fetch_body(filing) do
      {:ok, raw_text, content_hash} ->
        persist(filing, raw_text, content_hash)

      {:error, reason} ->
        Logger.warning(
          "FilingBodyFetcher: fetch failed for filing #{filing.id} " <>
            "(#{filing.filing_type}, url=#{filing.url}) — #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp persist(filing, raw_text, content_hash) do
    case Filings.create_filing_raw(
           %{
             filing_id: filing.id,
             raw_text: raw_text,
             content_hash: content_hash
           },
           actor: SystemActor.new()
         ) do
      {:ok, _raw} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "FilingBodyFetcher: persist failed for filing #{filing.id} — #{inspect(reason)}"
        )

        {:error, reason}
    end
  end
end
