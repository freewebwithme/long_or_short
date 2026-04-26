defmodule LongOrShort.News.Sources.Backoff do
  @moduledoc """
  Exponential backoff calculations for news source feeders.

  Pure functions — no state. The owning GenServer keeps `retry_count`
  in its state and asks this module for the next poll interval.

  Formula: `min(base_interval * 2^retry_count, max_interval)`.
  Capped at 5 minutes so a long outage doesn't push a feeder out
  to absurd intervals (and so recovery is observable within minutes
  of the source coming back).
  """

  @max_interval :timer.minutes(5)

  @doc """
  Returns the next poll interval in milliseconds given a base
  interval and the current retry count.

  At `retry_count = 0`, returns `base_interval` unchanged (i.e. the
  feeder's normal poll cadence after a successful fetch).
  """
  @spec next_interval(pos_integer(), non_neg_integer()) :: pos_integer()
  def next_interval(base_interval, retry_count)
      when is_integer(base_interval) and base_interval > 0 and
             is_integer(retry_count) and retry_count >= 0 do
    candidate = base_interval * Integer.pow(2, retry_count)
    min(candidate, @max_interval)
  end

  @doc "The maximum interval (5 minutes), exposed for tests and docs."
  def max_interval, do: @max_interval
end
