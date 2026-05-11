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

  @impl Oban.Worker
  def perform(_job) do
    sources = Application.get_env(:long_or_short, :enabled_news_sources, [])

    Enum.each(sources, &force_poll/1)

    :ok
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
