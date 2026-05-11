defmodule LongOrShortWeb.MorningBrief.Bucket do
  @moduledoc """
  Pure ET-time-bucket helper for the Morning Brief LiveView (LON-129).

  Translates `Article.published_at` (UTC) into the trader's mental
  model of the trading day in Eastern Time:

  | Bucket        | ET range                          |
  |---------------|-----------------------------------|
  | `:overnight`  | prev-day 16:00 → today 04:00      |
  | `:premarket`  | today 04:00 → 09:30               |
  | `:opening`    | today 09:30 → 10:30               |
  | `:regular`    | today 10:30 → 16:00               |
  | `:afterhours` | today 16:00 → 20:00               |
  | `:other`      | anything outside the above ranges |

  All functions take a `now` argument (default `DateTime.utc_now/0`)
  so tests can inject a frozen clock without `Application.put_env`
  hacks.

  Depends on `:tzdata` (see `config/config.exs`) for
  `"America/New_York"` resolution with DST.
  """

  @et_zone "America/New_York"

  @typedoc "The time-bucket classification returned by `bucket_for/2`."
  @type bucket ::
          :overnight | :premarket | :opening | :regular | :afterhours | :other

  @typedoc "The high-level view selected on the Morning Brief page."
  @type view_mode ::
          :premarket_brief | :opening | :intraday | :afterhours | :all_recent

  @doc "Current wall-clock time in ET."
  @spec et_now() :: DateTime.t()
  def et_now do
    DateTime.shift_zone!(DateTime.utc_now(), @et_zone)
  end

  @doc """
  Classify a UTC datetime into an ET bucket, anchored to `now`'s
  ET calendar day.

  Boundaries are half-open `[from, to)` — `04:00 ET` belongs to
  `:premarket`, not `:overnight`.
  """
  @spec bucket_for(DateTime.t(), DateTime.t()) :: bucket()
  def bucket_for(published_at, now \\ DateTime.utc_now())

  def bucket_for(%DateTime{} = published_at, %DateTime{} = now) do
    et_published = DateTime.shift_zone!(published_at, @et_zone)
    et_now = DateTime.shift_zone!(now, @et_zone)
    today = DateTime.to_date(et_now)
    yesterday = Date.add(today, -1)

    cond do
      in_range?(et_published, et_at(today, 16, 0), et_at(today, 20, 0)) -> :afterhours
      in_range?(et_published, et_at(today, 10, 30), et_at(today, 16, 0)) -> :regular
      in_range?(et_published, et_at(today, 9, 30), et_at(today, 10, 30)) -> :opening
      in_range?(et_published, et_at(today, 4, 0), et_at(today, 9, 30)) -> :premarket
      in_range?(et_published, et_at(yesterday, 16, 0), et_at(today, 4, 0)) -> :overnight
      true -> :other
    end
  end

  @doc """
  Pick the default view mode for the current ET time of day.

  | ET clock        | View mode           |
  |-----------------|---------------------|
  | 04:00–09:30     | `:premarket_brief`  |
  | 09:30–10:30     | `:opening`          |
  | 10:30–16:00     | `:intraday`         |
  | 16:00–20:00     | `:afterhours`       |
  | everything else | `:all_recent`       |
  """
  @spec default_view_for(DateTime.t()) :: view_mode()
  def default_view_for(now \\ DateTime.utc_now())

  def default_view_for(%DateTime{} = now) do
    et_now = DateTime.shift_zone!(now, @et_zone)
    minutes = et_now.hour * 60 + et_now.minute

    cond do
      minutes >= 4 * 60 and minutes < 9 * 60 + 30 -> :premarket_brief
      minutes >= 9 * 60 + 30 and minutes < 10 * 60 + 30 -> :opening
      minutes >= 10 * 60 + 30 and minutes < 16 * 60 -> :intraday
      minutes >= 16 * 60 and minutes < 20 * 60 -> :afterhours
      true -> :all_recent
    end
  end

  @doc """
  Returns `{since_utc, until_utc}` describing the time window the
  given view should fetch articles for.

  | Mode               | Window                              |
  |--------------------|-------------------------------------|
  | `:premarket_brief` | prev-day 16:00 ET → now             |
  | `:opening`         | last 60 minutes                     |
  | `:intraday`        | last 4 hours                        |
  | `:afterhours`      | today 16:00 ET → now                |
  | `:all_recent`      | last 24 hours                       |
  """
  @spec view_window(view_mode(), DateTime.t()) :: {DateTime.t(), DateTime.t()}
  def view_window(view_mode, now \\ DateTime.utc_now())

  def view_window(:premarket_brief, %DateTime{} = now) do
    et_now = DateTime.shift_zone!(now, @et_zone)
    today = DateTime.to_date(et_now)
    since = et_at(Date.add(today, -1), 16, 0) |> DateTime.shift_zone!("Etc/UTC")
    {since, now}
  end

  def view_window(:opening, %DateTime{} = now) do
    {DateTime.add(now, -60 * 60, :second), now}
  end

  def view_window(:intraday, %DateTime{} = now) do
    {DateTime.add(now, -4 * 3600, :second), now}
  end

  def view_window(:afterhours, %DateTime{} = now) do
    et_now = DateTime.shift_zone!(now, @et_zone)
    today = DateTime.to_date(et_now)
    since = et_at(today, 16, 0) |> DateTime.shift_zone!("Etc/UTC")
    {since, now}
  end

  def view_window(:all_recent, %DateTime{} = now) do
    {DateTime.add(now, -24 * 3600, :second), now}
  end

  # ── helpers ────────────────────────────────────────────────────

  # Build an ET datetime for `date` at `hour:minute:00`. Handles DST
  # transitions: in the spring-forward gap (clocks jump 02:00 → 03:00)
  # and fall-back overlap, we always return the **later** valid
  # instant. For trader-facing UI this is the safer default — a
  # premarket article from 04:00 ET should land in :premarket even
  # on the rare DST-change day.
  defp et_at(date, hour, minute) do
    ndt = NaiveDateTime.new!(date, Time.new!(hour, minute, 0))

    case DateTime.from_naive(ndt, @et_zone) do
      {:ok, dt} -> dt
      {:gap, _before, after_gap} -> after_gap
      {:ambiguous, _first, second} -> second
    end
  end

  defp in_range?(%DateTime{} = dt, %DateTime{} = from, %DateTime{} = to) do
    DateTime.compare(dt, from) != :lt and DateTime.compare(dt, to) == :lt
  end
end
