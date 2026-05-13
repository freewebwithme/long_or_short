defmodule LongOrShort.MorningBrief.CronWorker do
  @moduledoc """
  Oban cron worker for Morning Brief generation (LON-151).

  ## Schedule

  Configured via `Oban.Plugins.Cron` to fire every 15 minutes UTC
  (`"0,15,30,45 * * * *"`). The global Cron plugin runs on UTC — we
  can't promote a per-entry `timezone` without shifting the other
  UTC-anchored jobs (see comment in `config/config.exs`), so this
  worker does the ET time check itself.

  The three windows that trigger actual generation:

    * 05:00 ET — `:overnight`   (전일 마감 후 catalyst, Asia 마감, 선물)
    * 08:45 ET — `:premarket`   (8:30 ET 매크로 + 15분 인덱싱 버퍼)
    * 10:15 ET — `:after_open`  (10:00 ET 매크로 + 개장 30분 반응)

  Weekdays only (Mon–Fri). NYSE holidays (Thanksgiving, Christmas)
  are not filtered — the cost of a quiet-day brief is ~$0.07; if
  the noise gets annoying, a holiday-aware schedule is a separate
  ticket.

  ## Args

    * `%{}` — production. Worker self-selects bucket from current
      ET wall-clock; outside the three windows it no-ops.
    * `%{"bucket" => "overnight" | "premarket" | "after_open"}` —
      test override. Skips the time / weekday filter and runs the
      named bucket immediately.

  Anything else in `"bucket"` raises `FunctionClauseError`. Oban
  treats that as a job failure → retries up to `max_attempts` → then
  discards. That's the right surface for a programming bug; cron
  itself never passes a typo.

  ## Failure

  `Generator.generate_for_bucket/2` returning `{:error, _}` is
  bubbled up, so Oban's `max_attempts: 3` retry policy with
  exponential backoff kicks in. Transient API failures recover;
  persistent ones surface in the dashboard.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  alias LongOrShort.MorningBrief.Generator
  alias LongOrShortWeb.MorningBrief.Bucket

  @type bucket :: :overnight | :premarket | :after_open

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    bucket =
      case args["bucket"] do
        nil -> select_bucket(Bucket.et_now())
        "" -> select_bucket(Bucket.et_now())
        "overnight" -> :overnight
        "premarket" -> :premarket
        "after_open" -> :after_open
      end

    case bucket do
      nil -> :ok
      bucket -> run(bucket)
    end
  end

  @doc """
  Select the bucket to generate for at the given ET wall-clock, or
  `nil` if the current time is outside any brief window or it's the
  weekend.

  Public so unit tests can drive every branch with a frozen
  `DateTime` instead of depending on real time.
  """
  @spec select_bucket(DateTime.t()) :: bucket() | nil
  def select_bucket(%DateTime{} = et_now) do
    cond do
      not weekday?(et_now) -> nil
      et_now.hour == 5 and et_now.minute == 0 -> :overnight
      et_now.hour == 8 and et_now.minute == 45 -> :premarket
      et_now.hour == 10 and et_now.minute == 15 -> :after_open
      true -> nil
    end
  end

  # ── Internals ────────────────────────────────────────────────────

  defp run(bucket) do
    case Generator.generate_for_bucket(bucket) do
      {:ok, _digest} -> :ok
      {:error, _reason} = err -> err
    end
  end

  # ISO 8601 numbering: Monday = 1, Sunday = 7.
  defp weekday?(%DateTime{} = et_now) do
    Date.day_of_week(DateTime.to_date(et_now)) in 1..5
  end
end
