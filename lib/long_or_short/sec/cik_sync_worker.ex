defmodule LongOrShort.Sec.CikSyncWorker do
  @moduledoc """
  Daily Oban Cron worker that refreshes the SEC CIK ↔ ticker mapping.

  Replaces the fire-and-forget `Task.start` previously fired from
  `application.ex`, which suffered from:

    * Network call on every restart (10MB SEC dump, ~10K upserts)
    * Silent failures with no retry
    * Test churn — boot-time DB writes raced the SQL sandbox
    * Noisy query logs in dev on every iex restart

  Oban gives scheduling, automatic retries, and a queryable history
  via `oban_jobs`.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  alias LongOrShort.Sec.CikMapper

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    CikMapper.sync()
  end
end
