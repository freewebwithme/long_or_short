defmodule LongOrShort.Tickers.Workers.IwmUniverseSync do
  @moduledoc """
  Weekly Oban Cron worker that refreshes the small-cap universe by
  pulling iShares IWM ETF holdings (LON-133, Phase 0 of the two-tier
  dilution epic).

  For each equity row in the CSV:

    1. Upsert `LongOrShort.Tickers.Ticker` (enriches
       company_name/sector/exchange — CikMapper only populates
       symbol/cik/company_name).
    2. Upsert a `SmallCapUniverseMembership` row for source `:iwm`,
       bumping `last_seen_at` and re-activating any previously stale
       row.

  After the batch finishes, any `:iwm` membership whose
  `last_seen_at` predates this run's start is bulk-deactivated —
  the ticker is no longer in the IWM holdings list.

  ## Telemetry

  Emits `[:long_or_short, :small_cap_universe, :sync_complete]`
  with measurements `%{ok, errors, equity_rows, deactivated,
  active_universe_size}` and metadata `%{source: :iwm}`.

  ## Failure modes

  Fetch/parse errors return `{:error, reason}` and let Oban's
  `max_attempts: 3` retry policy take over. Per-row upsert errors
  are logged and counted but never abort the run — a single bad
  ticker can't poison the whole universe.
  """

  use Oban.Worker, queue: :default, max_attempts: 3
  require Logger
  require Ash.Query

  alias LongOrShort.Tickers
  alias LongOrShort.Tickers.Sources.IwmHoldings
  alias LongOrShort.Tickers.SmallCapUniverseMembership

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    batch_started_at = DateTime.utc_now()

    case IwmHoldings.fetch_and_parse() do
      {:ok, holdings} ->
        Logger.info(
          "IwmUniverseSync: parsed #{length(holdings)} equity holdings"
        )

        run(holdings, batch_started_at)
        :ok

      {:error, reason} = err ->
        Logger.error("IwmUniverseSync: fetch/parse failed — #{inspect(reason)}")
        err
    end
  end

  @doc false
  # Exposed for tests so they can drive the orchestration with fixture
  # holdings instead of mocking the HTTP fetch. Not part of the public API.
  def run(holdings, batch_started_at) do
    {ok_count, err_count} =
      Enum.reduce(holdings, {0, 0}, fn holding, {ok, err} ->
        case upsert_one(holding) do
          :ok -> {ok + 1, err}
          {:error, _} -> {ok, err + 1}
        end
      end)

    deactivated = deactivate_stale(batch_started_at)

    Logger.info(
      "IwmUniverseSync: complete — #{ok_count} ok, #{err_count} failed, " <>
        "#{deactivated} deactivated"
    )

    :telemetry.execute(
      [:long_or_short, :small_cap_universe, :sync_complete],
      %{
        ok: ok_count,
        errors: err_count,
        equity_rows: length(holdings),
        deactivated: deactivated,
        active_universe_size: ok_count
      },
      %{source: :iwm}
    )
  end

  defp upsert_one(%{symbol: symbol} = holding) do
    ticker_attrs = %{
      symbol: symbol,
      company_name: holding.name,
      sector: holding.sector,
      exchange: holding.exchange
    }

    with {:ok, ticker} <-
           Tickers.upsert_ticker_by_symbol(ticker_attrs, authorize?: false),
         {:ok, _membership} <-
           Tickers.upsert_small_cap_membership(
             %{ticker_id: ticker.id, source: :iwm},
             authorize?: false
           ) do
      :ok
    else
      {:error, reason} ->
        Logger.warning(
          "IwmUniverseSync: failed for #{symbol} — #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp deactivate_stale(batch_started_at) do
    # `type(..., :utc_datetime_usec)` is required: a bare `^batch_started_at`
    # is bound as `:utc_datetime` (second-precision) and truncates the
    # microseconds, which would group same-second upserts on the wrong side
    # of the boundary.
    result =
      SmallCapUniverseMembership
      |> Ash.Query.filter(
        source == :iwm and is_active == true and
          last_seen_at < type(^batch_started_at, :utc_datetime_usec)
      )
      |> Ash.bulk_update(:deactivate, %{},
        authorize?: false,
        return_records?: true,
        return_errors?: true
      )

    case result do
      %Ash.BulkResult{status: :success, records: records} ->
        length(records || [])

      %Ash.BulkResult{status: status, errors: errors} ->
        Logger.warning(
          "IwmUniverseSync: bulk deactivate finished as #{status}: " <>
            inspect(errors)
        )

        0
    end
  end
end
