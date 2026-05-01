defmodule Mix.Tasks.LongOrShort.SyncCik do
  @moduledoc """
  One-shot SEC CIK mapping sync.

  Use this on first DB setup to populate ticker rows synchronously,
  without waiting for the daily Oban cron.

      mix long_or_short.sync_cik
  """
  use Mix.Task

  @shortdoc "Sync the SEC CIK mapping into the tickers table"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    case LongOrShort.Sec.CikMapper.sync() do
      :ok -> :ok
      {:error, reason} -> Mix.raise("CIK sync failed: #{inspect(reason)}")
    end
  end
end
