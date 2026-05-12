defmodule LongOrShort.Sources.PipelineHelpers do
  @moduledoc """
  Shared scaffolding for the polling-lifecycle pipelines in
  `LongOrShort.News.Sources.Pipeline` and
  `LongOrShort.Filings.Sources.Pipeline`.

  These are the 100%-identical helper functions both pipelines need:

    * Scheduling (`schedule_first_poll/1`, `schedule_next/1`)
    * Source-state observability (`last_success_age_ms/1`,
      `update_source_state/2`)
    * Error handling with exponential backoff (`handle_error/3`)
    * Per-item parse with standard warning log (`parse_one/2`)

  Per-domain logic (News' dedup + raw_payload + broadcast, Filings'
  configurable sink) stays in the respective pipeline modules — these
  helpers only cover what is genuinely shared.

  Extracted in LON-142 from the 2026-05-12 code duplication audit.
  """

  require Logger

  alias LongOrShort.Accounts.SystemActor
  alias LongOrShort.News.Sources.Backoff
  alias LongOrShort.Sources

  @poll_message :poll

  @doc """
  Schedules the feeder's first poll, deferring if the previous run's
  `last_success_at` is more recent than `poll_interval_ms` ago. Used
  from `init/1` after process start.
  """
  @spec schedule_first_poll(module()) :: reference()
  def schedule_first_poll(module) do
    interval = module.poll_interval_ms()

    case last_success_age_ms(module) do
      nil ->
        schedule_next(0)

      age_ms when age_ms >= interval ->
        schedule_next(0)

      age_ms ->
        delay = interval - age_ms

        Logger.info(
          "#{inspect(module)}: deferring first poll by #{delay}ms " <>
            "(last success #{age_ms}ms ago)"
        )

        schedule_next(delay)
    end
  end

  @doc """
  Schedules the next `:poll` message after `interval_ms`.
  """
  @spec schedule_next(non_neg_integer()) :: reference()
  def schedule_next(interval_ms), do: Process.send_after(self(), @poll_message, interval_ms)

  @doc """
  Returns the age (in ms) of the feeder's most recent successful poll,
  or `nil` if no success has been recorded yet.
  """
  @spec last_success_age_ms(module()) :: non_neg_integer() | nil
  def last_success_age_ms(module) do
    case Sources.get_source_state(module.source_name(), authorize?: false) do
      {:ok, %{last_success_at: %DateTime{} = dt}} ->
        DateTime.diff(DateTime.utc_now(), dt, :millisecond)

      _ ->
        nil
    end
  end

  @doc """
  Persists the feeder's source state. `:success` stamps `last_success_at`
  and clears `last_error`; `{:error, reason}` only sets `last_error`.
  """
  @spec update_source_state(module(), :success | {:error, term()}) :: {:ok, term()} | {:error, term()}
  def update_source_state(module, :success) do
    Sources.upsert_source_state(
      %{
        source: module.source_name(),
        last_success_at: DateTime.utc_now(),
        last_error: nil
      },
      actor: SystemActor.new()
    )
  end

  def update_source_state(module, {:error, reason}) do
    Sources.upsert_source_state(
      %{
        source: module.source_name(),
        last_error: inspect(reason)
      },
      actor: SystemActor.new()
    )
  end

  @doc """
  Standard error-branch handler. Bumps `:retry_count`, computes the next
  interval via `Backoff.next_interval/2`, logs a warning, persists the
  error to source state, and schedules the next poll. Returns the
  GenServer `{:noreply, state}` reply directly so callers can use it as
  a tail expression.
  """
  @spec handle_error(module(), term(), map()) :: {:noreply, map()}
  def handle_error(module, reason, state) do
    retry_count = Map.get(state, :retry_count, 0) + 1
    next_interval = Backoff.next_interval(module.poll_interval_ms(), retry_count)

    Logger.warning(
      "Poll error in #{inspect(module)}: #{inspect(reason)} " <>
        "(retry=#{retry_count}, next in #{next_interval}ms)"
    )

    update_source_state(module, {:error, reason})

    next_state = Map.put(state, :retry_count, retry_count)
    schedule_next(next_interval)
    {:noreply, next_state}
  end

  @doc """
  Parses one raw item via `module.parse_response/1`, logging a warning
  and dropping on `{:error, _}`. Returns the result tuple unchanged.
  """
  @spec parse_one(module(), term()) :: {:ok, [map()]} | {:error, term()}
  def parse_one(module, raw) do
    case module.parse_response(raw) do
      {:ok, attrs_list} ->
        {:ok, attrs_list}

      {:error, reason} ->
        Logger.warning(
          "parse_response error in #{inspect(module)}: " <>
            "#{inspect(reason)} (raw item dropped)"
        )

        {:error, reason}
    end
  end
end
