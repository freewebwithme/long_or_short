defmodule LongOrShort.Filings.SeverityRules do
  @moduledoc """
  Hand-written severity rules for SEC filing dilution analysis (LON-114).

  **Severity is set by code rules — never by the LLM.** This is the
  central architectural decision of the LON-106 dilution epic
  (key architectural decision #2): keep the LLM strictly to factual
  extraction, and let deterministic, auditable rules grade severity.

  ## Rule contract

  Each rule is a pure function with arity-2:

      rule_xxx(extraction :: map(), ticker_context :: map()) ::
        {severity_atom, rule_name_atom, reason_string} | nil

  Returning `nil` means "this rule did not fire". Returning a 3-tuple
  means it did, with the severity, the rule name (for audit logs and
  the matched-rules list), and a human-readable reason string for the
  UI.

  ## ticker_context

  A map carrying everything a rule might need beyond the extraction
  itself. The orchestrator (`LongOrShort.Filings.Scoring`) builds it.

      %{
        ticker:             %Ticker{...},   # required
        filing:             %Filing{...},   # required
        rvol:               4.2,            # optional — relative volume vs 30d avg
        recent_catalyst?:   true,           # optional — article catalyst within 7d
        has_active_shelf?:  true,           # optional — ticker has an open S-3 shelf
        has_active_atm?:    true,           # optional — ticker has an active ATM program
        now:                ~U[...]         # optional — overridable for tests
      }

  When an optional key is missing, rules that depend on it return `nil`
  (the rule simply doesn't fire). This lets the rule set ship now and
  light up incrementally as supporting infrastructure (PriceBar/RVOL,
  per-ticker filing history) lands.

  ## Severity scale

  `:critical > :high > :medium > :low` (with `:none` reserved for "no
  rule fired"). The Scoring orchestrator picks the highest severity
  among matched rules as the overall.

  ## The default-low rule

  `rule_default_low/2` is **not** in `all_rules/0` — Scoring calls it
  only when no other rule fires, so it acts as the "any dilution event,
  graded `:low` if nothing else applies" catch-all per the LON-114 spec.
  This avoids it always firing alongside higher-severity rules and
  cluttering the matched-rules audit.

  ## Adding a new rule

  When the trader encounters a new dilution case post-launch:

  1. Add a new `rule_xxx/2` function with `@doc` explaining the domain
     reason (what dilution pattern it catches and why that severity).
  2. Add unit tests with positive, negative, and boundary cases.
  3. Append the rule name to `all_rules/0`.
  4. PR with the case description.

  This is the incremental-learning loop the LON-106 v2 spec depends on.

  ## Improving rule accuracy over time

  The Phase 1 thresholds (50% float, 30% float, 7-day / 14-day / 90-day
  windows) and severity assignments are **expert priors**, not
  empirically tuned values. Future improvements:

    1. **Outcome tracking** — log every rule firing with the filing
       and a snapshot of the ticker's price + volume. After 30/60/90
       days, record the actual price reaction (drawdown %, follow-on
       dilution events). Builds the dataset needed to calibrate
       severity against real trader pain.
    2. **Threshold backtesting** — sweep the magic numbers
       (50%/30%/20%, 7d/14d/90d) over the outcome dataset. False-
       positive vs. false-negative curves at each threshold reveal
       whether `:critical` should kick in at 40% or 60%, etc.
    3. **Severity recalibration** — `:critical / :high / :medium / :low`
       was assigned a priori. Compare each rule's average outcome to
       the rule that empirically *should* sit at the same level.
       Some `:high` rules may belong at `:critical` and vice versa.
    4. **Combined-rule severity** — two `:high` rules firing together
       likely warrants `:critical` overall, but Phase 1 just picks the
       max. Add explicit "combo" rules
       (e.g. `rule_atm_overhang_with_recent_pipe`) once outcome data
       supports them.
    5. **Per-ticker baseline** — some tickers are habitually at-the-
       market (ATM is part of normal operations); others rarely use
       it (ATM is the signal itself). A per-ticker baseline of
       "expected dilution noise" sharpens the signal-to-noise ratio.
    6. **Cross-reference signals** — Form 4 insider selling (LON-118),
       news-catalyst co-occurrence (LON-117), price-reaction history
       (LON-105) all add corroborating evidence. New rules can require
       *both* an extraction fact and a corroborating signal to fire.
    7. **Trader feedback loop** — surface a small "agree / too high /
       too low" widget on the dilution profile UI. Each click is a
       labeled training point for severity recalibration.
    8. **New rule discovery** — dilution patterns evolve (new
       structures, new gaming of regulations). The discipline is the
       same as the rule-add workflow above; the trigger is empirical
       outcome data showing a class of filings where current rules
       systematically miss.

  None of this requires an LLM. Severity stays code-determined; the
  loop just makes the code smarter over time.
  """

  alias LongOrShort.Filings.Filing
  alias LongOrShort.Tickers.Ticker

  @type severity :: :critical | :high | :medium | :low
  @type result :: {severity(), atom(), String.t()} | nil

  @typedoc """
  Per-rule context bundle. See moduledoc for field semantics.
  """
  @type ticker_context :: %{
          required(:ticker) => Ticker.t(),
          required(:filing) => Filing.t(),
          optional(:rvol) => number(),
          optional(:recent_catalyst?) => boolean(),
          optional(:has_active_shelf?) => boolean(),
          optional(:has_active_atm?) => boolean(),
          optional(:now) => DateTime.t()
        }

  # Severity ranking — earlier = more severe.
  @severity_levels [:critical, :high, :medium, :low]

  # Rules in the standard rotation. Excludes rule_default_low, which is
  # invoked by Scoring only when no rule here fires.
  @rules [
    :rule_atm_majority_of_float,
    :rule_atm_significant_overhang,
    :rule_atm_active_during_spike,
    :rule_recent_s1_filing,
    :rule_active_shelf_with_atm,
    :rule_warrant_overhang_in_money,
    :rule_recent_reverse_split,
    :rule_recent_pipe,
    :rule_death_spiral_convertible
  ]

  @doc "List of rule function names in evaluation order."
  @spec all_rules() :: [atom()]
  def all_rules, do: @rules

  @doc "Severity atoms in descending order of severity."
  @spec severity_levels() :: [severity()]
  def severity_levels, do: @severity_levels

  # ── Rule 1: ATM majority of float (critical) ───────────────────

  @doc """
  Fires when an active ATM program has remaining capacity exceeding
  50% of the ticker's free float.

  Domain reason: an ATM with this much overhang gives the company the
  ability to roughly double the float at any time without further
  notice, which is the worst possible setup for an existing holder.
  Treated as `:critical`.
  """
  @spec rule_atm_majority_of_float(map(), ticker_context()) :: result()
  def rule_atm_majority_of_float(
        %{dilution_type: :atm, atm_remaining_shares: rem},
        %{ticker: %Ticker{float_shares: float}}
      )
      when is_integer(rem) and is_integer(float) and float > 0 and rem / float > 0.5 do
    pct = Float.round(rem / float * 100, 1)

    {:critical, :rule_atm_majority_of_float,
     "ATM remaining shares > 50% of float (#{format_int(rem)}/#{format_int(float)}, #{pct}%)"}
  end

  def rule_atm_majority_of_float(_, _), do: nil

  # ── Rule 2: ATM significant overhang (high) ────────────────────

  @doc """
  Fires when ATM remaining capacity is 20–50% of float.

  Domain reason: serious overhang short of catastrophic. The company
  can meaningfully dilute on any rally but not single-handedly double
  the float. Treated as `:high`.
  """
  @spec rule_atm_significant_overhang(map(), ticker_context()) :: result()
  def rule_atm_significant_overhang(
        %{dilution_type: :atm, atm_remaining_shares: rem},
        %{ticker: %Ticker{float_shares: float}}
      )
      when is_integer(rem) and is_integer(float) and float > 0 do
    ratio = rem / float

    if ratio > 0.20 and ratio <= 0.50 do
      pct = Float.round(ratio * 100, 1)

      {:high, :rule_atm_significant_overhang,
       "ATM remaining shares #{pct}% of float (#{format_int(rem)}/#{format_int(float)})"}
    else
      nil
    end
  end

  def rule_atm_significant_overhang(_, _), do: nil

  # ── Rule 3: ATM active during spike (high) ─────────────────────

  @doc """
  Fires when an active ATM coincides with a price/volume spike or a
  recent news catalyst (within 7 days).

  Domain reason: ATMs are designed to be sold *into* strength — a
  rally on heavy volume is exactly when the company will be active.
  An ATM in the middle of a spike is a strong signal the rally is
  being supplied with fresh issuance.

  Requires either `context.rvol > 3.0` or
  `context.recent_catalyst? == true` to fire. Returns `nil` until
  the supporting infrastructure (PriceBar / news-catalyst signal)
  is in place to populate these context fields.
  """
  @spec rule_atm_active_during_spike(map(), ticker_context()) :: result()
  def rule_atm_active_during_spike(%{dilution_type: :atm}, %{rvol: rvol})
      when is_number(rvol) and rvol > 3.0 do
    {:high, :rule_atm_active_during_spike,
     "Active ATM during volume spike (RVOL #{Float.round(rvol * 1.0, 1)}×)"}
  end

  def rule_atm_active_during_spike(%{dilution_type: :atm}, %{recent_catalyst?: true}) do
    {:high, :rule_atm_active_during_spike,
     "Active ATM during recent news catalyst (within 7 days)"}
  end

  def rule_atm_active_during_spike(_, _), do: nil

  # ── Rule 4: Recent S-1 filing (high) ───────────────────────────

  @doc """
  Fires when the filing is an S-1 or S-1/A filed within the last 14 days.

  Domain reason: a fresh S-1 means new equity is being registered for
  imminent sale. The 14-day window catches the initial filing plus
  amendments leading up to pricing. Treated as `:high`.
  """
  @spec rule_recent_s1_filing(map(), ticker_context()) :: result()
  def rule_recent_s1_filing(_extraction, %{filing: %Filing{filing_type: type, filed_at: filed_at}} = ctx)
      when type in [:s1, :s1a] and not is_nil(filed_at) do
    days = days_ago(filed_at, ctx)

    if days <= 14 do
      {:high, :rule_recent_s1_filing,
       "Recent #{format_type(type)} filing (#{days} days ago)"}
    else
      nil
    end
  end

  def rule_recent_s1_filing(_, _), do: nil

  # ── Rule 5: Active shelf with ATM (high) ───────────────────────

  @doc """
  Fires when the ticker has both an active S-3 shelf registration and
  an active ATM program drawing capacity from it.

  Domain reason: an ATM under an open shelf is the most efficient
  dilution vehicle available — the company can convert market activity
  into cash with no incremental disclosure. Treated as `:high`.

  Requires both `context.has_active_shelf?` and
  `context.has_active_atm?` to be `true`. These are typically computed
  from per-ticker filing history by the Scoring orchestrator.
  """
  @spec rule_active_shelf_with_atm(map(), ticker_context()) :: result()
  def rule_active_shelf_with_atm(_extraction, %{
        has_active_shelf?: true,
        has_active_atm?: true
      }) do
    {:high, :rule_active_shelf_with_atm,
     "Active S-3 shelf with ATM program drawing from it"}
  end

  def rule_active_shelf_with_atm(_, _), do: nil

  # ── Rule 6: Warrant overhang in the money (medium) ─────────────

  @doc """
  Fires when warrant overhang exceeds 30% of float and the warrant
  strike is below the current price (in the money).

  Domain reason: in-the-money warrants are highly likely to be
  exercised, converting into common at the strike — the company gets
  cash, holders get diluted. The 30% threshold marks "material"
  overhang. Treated as `:medium`.

  Phase 1 approximation: uses `share_count` from the extraction as the
  warrant count whenever the deal involves warrants
  (`warrant_strike != nil`). The schema doesn't separately distinguish
  warrant count from issued share count today.
  """
  @spec rule_warrant_overhang_in_money(map(), ticker_context()) :: result()
  def rule_warrant_overhang_in_money(
        %{warrant_strike: strike, share_count: count},
        %{ticker: %Ticker{float_shares: float, last_price: %Decimal{} = last_price}}
      )
      when is_number(strike) and strike > 0 and is_integer(count) and count > 0 and
             is_integer(float) and float > 0 do
    last = Decimal.to_float(last_price)
    ratio = count / float

    if ratio > 0.30 and strike < last do
      pct = Float.round(ratio * 100, 1)

      {:medium, :rule_warrant_overhang_in_money,
       "In-the-money warrant overhang: #{pct}% of float, strike $#{format_money(strike)} below current $#{format_money(last)}"}
    else
      nil
    end
  end

  def rule_warrant_overhang_in_money(_, _), do: nil

  # ── Rule 7: Recent reverse split (high) ────────────────────────

  @doc """
  Fires when a reverse-split-related filing was made within the last
  90 days.

  Domain reason: reverse splits are most often a Nasdaq listing-cure
  signal (price below $1 for 30 days), and historically precede further
  dilution rounds rather than mark a turnaround. The 90-day window
  catches both the proxy approval and the execution event. Treated as
  `:high`.
  """
  @spec rule_recent_reverse_split(map(), ticker_context()) :: result()
  def rule_recent_reverse_split(
        %{dilution_type: :reverse_split},
        %{filing: %Filing{filed_at: filed_at}} = ctx
      )
      when not is_nil(filed_at) do
    days = days_ago(filed_at, ctx)

    if days <= 90 do
      {:high, :rule_recent_reverse_split, "Recent reverse split activity (#{days} days ago)"}
    else
      nil
    end
  end

  def rule_recent_reverse_split(_, _), do: nil

  # ── Rule 8: Recent PIPE (critical) ─────────────────────────────

  @doc """
  Fires when a PIPE (private investment in public equity) was disclosed
  within the last 7 days.

  Domain reason: PIPEs are typically priced at a discount to market
  with warrants attached. The disclosure itself often triggers a sharp
  selloff as PIPE investors hedge by shorting common. The 7-day window
  captures the active reaction period. Treated as `:critical`.
  """
  @spec rule_recent_pipe(map(), ticker_context()) :: result()
  def rule_recent_pipe(
        %{dilution_type: :pipe},
        %{filing: %Filing{filed_at: filed_at}} = ctx
      )
      when not is_nil(filed_at) do
    days = days_ago(filed_at, ctx)

    if days <= 7 do
      {:critical, :rule_recent_pipe, "Recent PIPE deal (#{days} days ago)"}
    else
      nil
    end
  end

  def rule_recent_pipe(_, _), do: nil

  # ── Rule 9: Death-spiral convertible (critical) ────────────────

  @doc """
  Fires when extraction flags a death-spiral convertible
  (floating discount-to-market conversion).

  Domain reason: a convertible whose conversion price floats with the
  market gets cheaper as the stock falls — every conversion creates
  more shares to sell, pushing the price further down, enabling cheaper
  conversions. The classic small-cap melt structure. Always
  `:critical` regardless of size.
  """
  @spec rule_death_spiral_convertible(map(), ticker_context()) :: result()
  def rule_death_spiral_convertible(%{has_death_spiral_convertible: true}, _) do
    {:critical, :rule_death_spiral_convertible,
     "Death-spiral convertible (floating discount-to-market conversion)"}
  end

  def rule_death_spiral_convertible(_, _), do: nil

  # ── Default-low fallback (called by Scoring when no rule fires) ──

  @doc """
  Fallback that fires only when no other rule fires but the extraction
  shows some dilution event (`dilution_type != :none` and not nil).

  Treated as `:low` — there is dilution, but nothing in the rule set
  matched a known severity pattern. Surfaces the case for trader
  attention without overstating it.

  Not included in `all_rules/0`; the Scoring orchestrator invokes this
  conditionally.
  """
  @spec rule_default_low(map(), ticker_context()) :: result()
  def rule_default_low(%{dilution_type: type}, _) when type not in [nil, :none] do
    {:low, :rule_default_low, "Dilution event of type #{format_type(type)}"}
  end

  def rule_default_low(_, _), do: nil

  # ── Helpers ────────────────────────────────────────────────────

  defp days_ago(%DateTime{} = dt, ctx) do
    now = Map.get(ctx, :now, DateTime.utc_now())
    DateTime.diff(now, dt, :day)
  end

  defp format_int(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp format_money(n) when is_number(n) do
    n |> :erlang.float_to_binary(decimals: 2)
  end

  # `dilution_type` and `filing_type` enums share this lookup. Anything
  # not listed falls back to `Atom.to_string` for safety.
  defp format_type(:atm), do: "ATM"
  defp format_type(:s1), do: "S-1"
  defp format_type(:s1a), do: "S-1/A"
  defp format_type(:s3), do: "S-3"
  defp format_type(:s3a), do: "S-3/A"
  defp format_type(:_424b1), do: "424B1"
  defp format_type(:_424b2), do: "424B2"
  defp format_type(:_424b3), do: "424B3"
  defp format_type(:_424b4), do: "424B4"
  defp format_type(:_424b5), do: "424B5"
  defp format_type(:_8k), do: "8-K"
  defp format_type(:_13d), do: "Schedule 13D"
  defp format_type(:_13g), do: "Schedule 13G"
  defp format_type(:def14a), do: "DEF 14A"
  defp format_type(:form4), do: "Form 4"
  defp format_type(:s1_offering), do: "S-1 offering"
  defp format_type(:s3_shelf), do: "S-3 shelf"
  defp format_type(:pipe), do: "PIPE"
  defp format_type(:warrant_exercise), do: "warrant exercise"
  defp format_type(:convertible_conversion), do: "convertible conversion"
  defp format_type(:reverse_split), do: "reverse split"
  defp format_type(:none), do: "none"
  defp format_type(other) when is_atom(other), do: Atom.to_string(other)
end
