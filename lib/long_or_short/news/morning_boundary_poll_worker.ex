defmodule LongOrShort.News.MorningBoundaryPollWorker do
  @moduledoc """
  Forces an immediate poll on every enabled news source at the
  trader's morning catalyst boundaries.

  Scheduled via `Oban.Plugins.Cron` for **ET 07:00, 07:30, 08:00,
  08:30, 09:00, 09:30, 10:00, 10:30 Mon–Fri** — the "top of the
  hour" / "bottom of the hour" windows where company earnings,
  FDA decisions, jobs reports, and other market-moving catalysts
  typically drop.

  Without this, our 60s polling timers can be up to 60s out of
  phase with a `:00`/`:30` boundary, costing the trader entry
  latency when minutes matter.

  ## Idempotent

  Each force-poll fires the same `:poll` message the GenServer's
  own timer fires, so the source's `Pipeline.run_poll/2` handles
  it identically. The dedup layer (`(source, external_id,
  symbol)`) absorbs any duplicate articles a force-poll and the
  next timer-poll might both pull within the same 60s window.

  ## Holidays

  The cron runs Mon–Fri unconditionally — we don't filter NYSE
  holidays (Thanksgiving, Christmas). On a market-closed day each
  fetch simply returns 0 new articles. Cheap no-op. A
  holiday-aware schedule is a separate ticket if the noise
  becomes annoying.
  """

  use Oban.Worker, queue: :default

  require Logger

  @et_zone "America/New_York"

  @impl Oban.Worker
  def perform(_job), do: tick(DateTime.utc_now())

  @doc """
  Runs a single boundary evaluation against the given UTC `now`.

  Public so tests can inject a frozen clock — there's no
  `Application.put_env` hack and no need to start the real feeder
  GenServers during a test run.
  """
  @spec tick(DateTime.t()) :: :ok
  def tick(now) do
    et_now = DateTime.shift_zone!(now, @et_zone)

    if boundary?(et_now), do: dispatch()

    :ok
  end

  # Cron fires UTC every :00 / :30 (24 × 2 = 48 invocations / day);
  # only ~8 of those fall inside the ET morning window we actually
  # care about. The rest return :ok without doing any work — cheap
  # no-op compared with maintaining a DST-aware UTC cron schedule
  # twice a year.
  defp boundary?(%DateTime{hour: hour, minute: minute} = et_now) do
    weekday? = Date.day_of_week(DateTime.to_date(et_now)) in 1..5
    weekday? and hour in 7..10 and minute in [0, 30]
  end

  defp dispatch do
    sources = Application.get_env(:long_or_short, :enabled_news_sources, [])
    Enum.each(sources, &force_poll/1)
  end

  defp force_poll(module) do
    case Process.whereis(module) do
      nil ->
        Logger.warning(
          "MorningBoundaryPollWorker: #{inspect(module)} is enabled but its " <>
            "GenServer isn't running — skipping force-poll."
        )

      pid ->
        send(pid, :poll)
    end
  end
end
