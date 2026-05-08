defmodule LongOrShort.Filings.Sources.Pipeline do
  @moduledoc """
  Stateless helper for the polling lifecycle of `Filings.Source`
  feeders.

  Mirrors `LongOrShort.News.Sources.Pipeline` but routes parsed
  attributes to a configurable ingestion sink rather than
  `News.ingest_article/2`.

  ## State shape

  Pipeline owns one reserved key in the GenServer state:

    * `:retry_count` — non-negative integer, advanced on
      `fetch_filings/1` errors and reset on success. Drives the
      shared `News.Sources.Backoff`.

  Feeders may add any other keys (per-type cursors, etc.) — `init/2`
  accepts a `:state` opt and `run_poll/2` only touches its own keys.

  ## Ingest sink

  The Stage 2 ticket (LON-112) introduces the `Filings` Ash domain
  and a `Filings.ingest_filing/1` code interface. Until then this
  pipeline routes parsed attributes through a configurable sink
  function so the feeder is fully testable today and Stage 2 can
  swap the sink with a one-line config change.

  Resolution order, evaluated per call:

    1. `:ingest_fun` opt passed to `init/2` (test-only)
    2. `Application.get_env(:long_or_short, :filings_ingest_fun)`
    3. Default: `&log_and_drop/1`

  The sink contract is `(attrs :: map()) -> {:ok, term()} | {:error, term()}`.

  ## Per-item resilience

  A bad parse on one raw item, or an ingest failure on one filing,
  does not abort the batch. Only `fetch_filings/1` returning
  `{:error, ...}` triggers backoff — that's a source-wide problem.
  """

  require Logger

  alias LongOrShort.Accounts.SystemActor
  alias LongOrShort.News.Sources.Backoff
  alias LongOrShort.Sources

  @poll_message :poll

  @doc """
  Initial state + first poll. Call from the feeder's `init/1`.

  ## Options

    * `:state` — initial custom state map (default: `%{}`)
    * `:ingest_fun` — overrides the configured ingest sink
      (test-only; production should configure via app env)
  """
  @spec init(module(), keyword()) :: {:ok, map()}
  def init(module, opts \\ []) do
    initial_custom = Keyword.get(opts, :state, %{})

    state =
      initial_custom
      |> Map.merge(%{retry_count: 0})
      |> maybe_put_ingest_fun(opts)

    schedule_first_poll(module)
    {:ok, state}
  end

  @doc """
  Run a single polling cycle. Call from the feeder's
  `handle_info(:poll, state)`.
  """
  @spec run_poll(module(), map()) :: {:noreply, map()}
  def run_poll(module, state) do
    case module.fetch_filings(state) do
      {:ok, raw_items, new_state} ->
        handle_success(module, raw_items, new_state)

      {:error, reason, new_state} ->
        handle_error(module, reason, new_state)
    end
  end

  defp handle_success(module, raw_items, state) do
    {ingested, errored} = process_batch(module, raw_items, state)

    Logger.debug(fn ->
      "Polled #{inspect(module)}: " <>
        "#{ingested} ingested, #{errored} errored " <>
        "(#{length(raw_items)} raw)"
    end)

    update_source_state(module, :success)

    next_state = Map.put(state, :retry_count, 0)
    schedule_next(module.poll_interval_ms())
    {:noreply, next_state}
  end

  defp process_batch(module, raw_items, state) do
    Enum.reduce(raw_items, {0, 0}, fn raw, {ing, err} ->
      case parse_one(module, raw) do
        {:ok, attrs_list} ->
          Enum.reduce(attrs_list, {ing, err}, fn attrs, acc -> handle_attrs(attrs, acc, state) end)

        {:error, _reason} ->
          {ing, err + 1}
      end
    end)
  end

  defp parse_one(module, raw) do
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

  defp handle_attrs(attrs, {ing, err}, state) do
    case attrs do
      %{source: _source, external_id: _ext_id, symbol: _sym, filing_type: _ft} ->
        case ingest(attrs, state) do
          {:ok, _} -> {ing + 1, err}
          {:error, _} -> {ing, err + 1}
        end

      _malformed ->
        Logger.warning(
          "Malformed attrs from parse_response (missing source/external_id/symbol/filing_type): " <>
            inspect(attrs)
        )

        {ing, err + 1}
    end
  end

  defp ingest(attrs, state) do
    fun = ingest_fun(state)

    case fun.(attrs) do
      {:ok, _} = ok ->
        ok

      {:error, reason} = err ->
        Logger.warning(
          "filings ingest failed for " <>
            "(#{attrs[:source]}, #{attrs[:filing_type]}, #{attrs[:external_id]}, #{attrs[:symbol]}): " <>
            "#{inspect(reason)}"
        )

        err
    end
  end

  defp handle_error(module, reason, state) do
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

  defp schedule_first_poll(module) do
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

  defp schedule_next(interval_ms), do: Process.send_after(self(), @poll_message, interval_ms)

  defp last_success_age_ms(module) do
    case Sources.get_source_state(module.source_name(), authorize?: false) do
      {:ok, %{last_success_at: %DateTime{} = dt}} ->
        DateTime.diff(DateTime.utc_now(), dt, :millisecond)

      _ ->
        nil
    end
  end

  defp update_source_state(module, :success) do
    Sources.upsert_source_state(
      %{
        source: module.source_name(),
        last_success_at: DateTime.utc_now(),
        last_error: nil
      },
      actor: SystemActor.new()
    )
  end

  defp update_source_state(module, {:error, reason}) do
    Sources.upsert_source_state(
      %{
        source: module.source_name(),
        last_error: inspect(reason)
      },
      actor: SystemActor.new()
    )
  end

  # ── Ingest sink resolution ───────────────────────────────────────

  defp maybe_put_ingest_fun(state, opts) do
    case Keyword.fetch(opts, :ingest_fun) do
      {:ok, fun} when is_function(fun, 1) -> Map.put(state, :ingest_fun, fun)
      :error -> state
    end
  end

  defp ingest_fun(state) do
    Map.get(state, :ingest_fun) ||
      Application.get_env(:long_or_short, :filings_ingest_fun) ||
      (&__MODULE__.log_and_drop/1)
  end

  @doc false
  # Default sink used until LON-112 wires `Filings.ingest_filing/1`.
  # Logs the parsed filing and returns `:ok` so the polling cycle
  # treats it as a successful per-item handle.
  def log_and_drop(attrs) do
    Logger.info(
      "Filings.Pipeline (no sink configured) — dropping parsed filing: " <>
        "source=#{attrs[:source]} type=#{attrs[:filing_type]} " <>
        "symbol=#{attrs[:symbol]} ext_id=#{attrs[:external_id]}"
    )

    {:ok, :dropped}
  end
end
