defmodule LongOrShort.Workers.BatchHelper do
  @moduledoc """
  Shared batch-processing plumbing for Oban workers in this codebase.

  Four workers under `lib/long_or_short/filings/workers/` reimplement
  the same shape: reduce a list of items, count outcomes, optionally
  sleep between items, emit a `[:long_or_short, _, :complete]`
  telemetry event. Two of them are 2-state (ok / error); two are
  3-state (ok / error / skipped). This module factors out the
  reduce + telemetry; per-item domain logic (HTTP, parsing,
  analyzer dispatch) stays in the worker's `process_one/1`.

  Extracted in LON-141 from the 2026-05-12 code duplication audit.

  ## Usage

      defp run_batch(items, total) do
        Logger.info("MyWorker: processing total items")

        counts =
          BatchHelper.process_batch(items, &process_one/1,
            initial: %{ok: 0, error: 0, skipped: 0},
            per_item_pause_ms: 150
          )

        Logger.info("MyWorker: complete")
        BatchHelper.emit_complete_telemetry(:my_worker, counts, total)
        :ok
      end

  `process_one/1` must return one of `:ok | {:ok, _} | :skip |
  {:skip, _} | :error | {:error, _}`. Anything else raises.
  """

  @type counts :: %{required(atom()) => non_neg_integer()}
  @type process_result :: :ok | {:ok, any()} | :skip | {:skip, any()} | :error | {:error, any()}

  @doc """
  Reduces `items` through `process_fn`, accumulating into a counter
  map.

  ## Options

    * `:initial` — starting counters. Defaults to `%{ok: 0, error: 0}`.
      Pass `%{ok: 0, error: 0, skipped: 0}` for 3-state workers.
    * `:per_item_pause_ms` — `Process.sleep` between items (skipped
      for the first). Defaults to `0`.
  """
  @spec process_batch([term()], (term() -> process_result()), keyword()) :: counts()
  def process_batch(items, process_fn, opts \\ []) when is_function(process_fn, 1) do
    initial = Keyword.get(opts, :initial, %{ok: 0, error: 0})
    pause_ms = Keyword.get(opts, :per_item_pause_ms, 0)

    items
    |> Enum.with_index()
    |> Enum.reduce(initial, fn {item, idx}, counts ->
      if idx > 0 and pause_ms > 0, do: Process.sleep(pause_ms)

      key = classify(process_fn.(item))
      Map.update(counts, key, 1, &(&1 + 1))
    end)
  end

  @doc """
  Emits `[:long_or_short, name, :complete]` with the counts + total
  as measurements. `metadata` is passed through unchanged.
  """
  @spec emit_complete_telemetry(atom(), counts(), non_neg_integer(), map()) :: :ok
  def emit_complete_telemetry(name, counts, total, metadata \\ %{})
      when is_atom(name) and is_map(counts) and is_integer(total) do
    measurements = Map.put(counts, :total, total)
    :telemetry.execute([:long_or_short, name, :complete], measurements, metadata)
  end

  defp classify(:ok), do: :ok
  defp classify({:ok, _}), do: :ok
  defp classify(:skip), do: :skipped
  defp classify({:skip, _}), do: :skipped
  defp classify(:error), do: :error
  defp classify({:error, _}), do: :error

  defp classify(other) do
    raise ArgumentError,
          "BatchHelper.process_batch/3: process_fn must return :ok | {:ok, _} | " <>
            ":skip | {:skip, _} | :error | {:error, _}, got #{inspect(other)}"
  end
end
