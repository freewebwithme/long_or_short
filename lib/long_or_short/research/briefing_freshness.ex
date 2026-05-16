defmodule LongOrShort.Research.BriefingFreshness do
  @moduledoc """
  Time-of-day cache TTL policy for `TickerBriefing` rows (LON-174, PT-3).

  Pre-Trade Briefing is the per-ticker `web_search`-backed research card
  produced on demand. `web_search` calls cost noticeably more than plain
  LLM calls — the cache TTL gates how often a fresh call fires, so the
  TTL is the primary cost-control lever after per-call knobs (LON-179).

  The right TTL varies with how fast the world changes for the trader:

      | ET window                | TTL    | Why                                 |
      | ------------------------ | ------ | ----------------------------------- |
      | Premarket  04:00–09:30   | 5 min  | Catalysts arrive fast; trader is    |
      |                          |        | minutes from an entry decision      |
      | Regular    09:30–16:00   | 10 min | Active flow; news still moves price |
      | After-hrs  16:00–20:00   | 15 min | Information velocity drops          |
      | Overnight  20:00–04:00   | 60 min | Mostly quiet; intercontinental news |
      | Weekend (any hour)       | 4 hrs  | Market closed; almost nothing moves |

  Implemented as pure functions over a passed-in ET-zone `DateTime` so
  tests can pin the wall-clock without touching system time. The
  `et_now/0` convenience wraps UTC→ET conversion for the production
  call site in `BriefingGenerator`.
  """

  @type bucket :: :premarket | :regular | :after_hours | :overnight | :weekend

  @premarket_ttl_seconds 5 * 60
  @regular_ttl_seconds 10 * 60
  @after_hours_ttl_seconds 15 * 60
  @overnight_ttl_seconds 60 * 60
  @weekend_ttl_seconds 4 * 60 * 60

  @doc """
  Returns the current Eastern Time as a `DateTime` in
  `"America/New_York"`. Uses `tzdata` (already a transitive Phoenix
  dependency) so DST transitions are honored.

  Callers should prefer pinning `et_now` explicitly in tests rather
  than mocking system time.
  """
  @spec et_now() :: DateTime.t()
  def et_now do
    DateTime.utc_now() |> DateTime.shift_zone!("America/New_York")
  end

  @doc """
  Classifies an ET wall-clock into a bucket label. Exposed alongside
  `ttl_seconds/1` so callers (e.g. dashboard widgets) that want to
  show "Premarket — cached for 5 min" can render the bucket name
  without a second branch.
  """
  @spec bucket(DateTime.t()) :: bucket()
  def bucket(%DateTime{} = et_now) do
    cond do
      weekend?(et_now) -> :weekend
      in_window?(et_now, {4, 0}, {9, 30}) -> :premarket
      in_window?(et_now, {9, 30}, {16, 0}) -> :regular
      in_window?(et_now, {16, 0}, {20, 0}) -> :after_hours
      true -> :overnight
    end
  end

  @doc """
  TTL in seconds for the bucket containing `et_now`.

  `BriefingGenerator.build_attrs/7` calls this with the same `et_now`
  it threads through the whole generation, so the persisted
  `cached_until` always lines up with the bucket that authored the
  row — important when a generation straddles a bucket boundary
  (e.g. starts at 09:29:55 premarket, persists at 09:30:03 regular).
  """
  @spec ttl_seconds(DateTime.t()) :: pos_integer()
  def ttl_seconds(%DateTime{} = et_now) do
    case bucket(et_now) do
      :premarket -> @premarket_ttl_seconds
      :regular -> @regular_ttl_seconds
      :after_hours -> @after_hours_ttl_seconds
      :overnight -> @overnight_ttl_seconds
      :weekend -> @weekend_ttl_seconds
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────

  defp weekend?(%DateTime{} = et_now) do
    Date.day_of_week(DateTime.to_date(et_now)) in [6, 7]
  end

  # Half-open `[start, end)` window in ET wall-clock minutes-of-day.
  # Half-open so adjacent buckets don't overlap at the boundary —
  # 09:30:00.000 cleanly belongs to `:regular`, not `:premarket`.
  defp in_window?(%DateTime{hour: h, minute: m}, {sh, sm}, {eh, em}) do
    minutes = h * 60 + m
    start_min = sh * 60 + sm
    end_min = eh * 60 + em
    minutes >= start_min and minutes < end_min
  end
end
