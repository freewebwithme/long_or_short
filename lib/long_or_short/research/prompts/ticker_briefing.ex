defmodule LongOrShort.Research.Prompts.TickerBriefing do
  @moduledoc """
  Prompt builder for the on-demand Pre-Trade Briefing (LON-172).

  Produces `[%{role: "system"}, %{role: "user"}]` shaped for
  `LongOrShort.AI.Providers.Claude.call_with_search/2`.

  ## System vs. user split — designed for PT-3 prompt caching

  The split is intentional and matters for [[LON-174]] (PT-3) prompt
  caching. Per Anthropic's `cache_control: ephemeral` mechanism,
  prefix-stable portions of the request get cached for ~5min at 10%
  cost. The system message holds **everything that doesn't change
  call-to-call for the same trader**:

    * Persona role declaration (depends on `trading_style`)
    * Profile bullets (depends on `TradingProfile` fields)
    * Output format spec (constant)
    * Search/tone rules (constant)

  Everything **variable** lives in the user message:

    * Ticker symbol / last_price / market cap context
    * Dilution profile JSON (changes as Tier 1/2 land new analyses)
    * Recent NewsAnalysis verdicts (changes constantly)
    * Wall-clock timestamp + "search the last 24h" instruction

  Don't relocate variable items into the system message — it would
  break prompt caching once PT-3 wires `cache_control`.

  ## Persona injection

  Reuses `LongOrShort.AI.Prompts.Persona` — the same module
  `NewsAnalysis` prompts use. Two surfaces sharing one persona
  description avoids "persona drift" where the briefing and the
  news-card verdict describe the user with different vocabulary.

  ## Output format

  Markdown narrative with 7 named sections (TL;DR, Catalyst,
  Sentiment, Dilution Risk, Recent News, Risk Factors, Position
  Sizing). The structured-data alternative — having the LLM call a
  tool that returns `%{catalyst, sentiment, risks, confirms}` — is a
  PT-4 enhancement. PT-1 stores `:structured => %{}` and renders the
  markdown directly.
  """

  alias LongOrShort.AI.Prompts.Persona

  @doc """
  Build the message list for `(ticker, profile, context)`.

  `context` is a map with optional keys:

    * `:dilution_profile` — output of
      `Tickers.get_dilution_profile/1`, or `nil` when unavailable
    * `:recent_news_analyses` — list of recent `NewsAnalysis` rows
      (default `[]`)
    * `:et_now` — DateTime override for tests; production omits this

  Returns `[system_msg, user_msg]`.
  """
  @spec build(map(), map(), map()) :: [map()]
  def build(ticker, profile, context \\ %{}) do
    [
      %{role: "system", content: system_prompt(profile)},
      %{role: "user", content: user_prompt(ticker, context)}
    ]
  end

  # ── System prompt (stable across calls for the same trader) ─────

  defp system_prompt(profile) do
    """
    You are an on-demand research analyst preparing a single-ticker
    briefing for a #{Persona.intro(profile.trading_style)} who is
    considering an entry. The trader has clicked "Brief" — they want
    a tight, decision-grade rundown in under a minute, not a research
    report.

    Trader profile:
    #{Persona.render_profile_lines(profile)}

    #{search_rules()}

    #{output_format()}

    #{tone_rules()}
    #{Persona.render_notes(profile.notes)}
    Speak like a trader, not an analyst. Korean is welcome where it
    reads naturally — the trader is bilingual.
    """
  end

  defp search_rules do
    """
    Search rules:
      * Use `web_search` to pull news, SEC filings (S-3, S-1, 424B*,
        8-K, DEF 14A, Form 4), earnings releases, and macro context
        from the last 24 hours. Sources older than that are
        background, not catalyst — except for dilution filings, where
        anything within 90 days is in-scope.
      * The user message provides internal context (recent NewsAnalysis
        verdicts, DilutionProfile). When either is marked missing /
        insufficient, lean harder on `web_search` to fill that
        specific gap.
      * Maximum 5 search calls. Synthesize, don't over-search.
      * Cite every fact with [1], [2], ... inline markers.
      * "No relevant information found" is a valid finding — say so.
        Do not fill space with generalities.
    """
  end

  defp output_format do
    """
    Output format — markdown, exactly these sections in this order:

    ## TL;DR
    1–2 sentences. The trader's actionable take. Lead with the verdict
    (`Watch`, `Skip`, `Trade`) followed by the single most important
    reason.

    ## Catalyst
    What is moving this ticker right now (or what is expected to move
    it intraday). Include specifics — exact filing type, exact news
    item, exact macro release. Distinguish strong catalysts (FDA,
    M&A, contract win with named counterparty) from weak ones (vague
    PR, recycled themes).

    ## Sentiment
    Bullish / bearish / mixed reading of the last 24h flow. Note
    sentiment **drivers** — what's pushing it that direction — not
    just the label.

    ## Dilution Risk
    Read the dilution context block in the user message. If `severe`
    or `high` overall_severity, treat this as a load-bearing factor.
    If `:insufficient` data, say so honestly — don't assume "clean."

    ## Recent News (last 24h)
    Bullet list of 3–6 items pulled from search. Each: one line +
    citation. Skip stale stuff.

    ## Risk Factors
    Specific things that would void the thesis. Anti-catalysts the
    trader should watch for during the session.

    ## Position Sizing Note
    One sentence calibrated to the trader's profile (price band,
    float cap, time horizon). Concrete — "small starter under $X,
    add on confirmation" beats "size appropriately."
    """
  end

  defp tone_rules do
    """
    Tone:
      * Direct. No hedging filler ("It is important to note that ...").
      * Call out fade risk explicitly when you see it.
      * If the catalyst is thin, say "thin catalyst" — don't soften.
      * No investment advice / recommendations to buy or sell. You
        are framing context; the trader decides.
    """
  end

  # ── User prompt (variable per call) ─────────────────────────────

  defp user_prompt(ticker, context) do
    et_now = Map.get(context, :et_now, DateTime.utc_now())

    [
      ticker_header(ticker, et_now),
      dilution_section(context[:dilution_profile]),
      recent_analyses_section(context[:recent_news_analyses] || []),
      search_instruction(et_now)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp ticker_header(ticker, et_now) do
    """
    ## Ticker
    Symbol: #{ticker.symbol}
    Company: #{ticker.company_name || "—"}
    Exchange: #{ticker.exchange || "—"}
    Industry: #{ticker.industry || "—"}
    Last price: #{format_price(ticker.last_price)}
    Shares outstanding: #{format_shares(ticker.shares_outstanding)}
    Float: #{format_shares(ticker.float_shares)}
    Current time (ET): #{DateTime.to_string(et_now)}
    """
  end

  defp dilution_section(nil) do
    """
    ## Dilution context
    Status: **internal data missing** — no `DilutionProfile` resolved
    for this ticker. Use `web_search` against SEC EDGAR's recent
    filings list for this symbol (S-3 / S-3/A, S-1 / S-1/A,
    424B1–B5, 8-K Item 3.02 unregistered sales, DEF 14A reverse-split
    proposals) within the last 90 days. Treat absence of findings as
    UNKNOWN, not clean.
    """
  end

  defp dilution_section(%{data_completeness: :insufficient}) do
    """
    ## Dilution context
    Status: **insufficient data** — Tier 1 ran but key signals
    couldn't be extracted. Fall back to `web_search` for recent SEC
    filings (S-3, 424B*, 8-K Item 3.02) to fill the gap. Treat
    dilution risk as UNKNOWN, not clean.
    """
  end

  defp dilution_section(profile) do
    """
    ## Dilution context
    ```json
    #{Jason.encode!(profile, pretty: true)}
    ```
    """
  end

  defp recent_analyses_section([]), do: ""

  defp recent_analyses_section(analyses) do
    """
    ## Recent NewsAnalysis verdicts (last 7 days, our own ingest)
    These are this trader's previously-recorded takes on news for
    this ticker. Use them for continuity — don't contradict a
    well-supported prior verdict without explicit reason.

    ```json
    #{Jason.encode!(Enum.map(analyses, &summarize_analysis/1), pretty: true)}
    ```
    """
  end

  defp summarize_analysis(a) do
    %{
      analyzed_at: a.analyzed_at,
      verdict: a.verdict,
      catalyst_strength: a.catalyst_strength,
      catalyst_type: a.catalyst_type,
      sentiment: a.sentiment,
      headline_takeaway: a.headline_takeaway
    }
  end

  defp search_instruction(et_now) do
    """
    ## Task
    Produce the briefing now. Use `web_search` for fresh information
    from the last 24 hours (current time: #{DateTime.to_string(et_now)}).
    Follow the 7-section output format exactly.
    """
  end

  # ── Formatting helpers ──────────────────────────────────────────

  defp format_price(nil), do: "—"
  defp format_price(%Decimal{} = d), do: "$#{Decimal.to_string(d)}"
  defp format_price(n) when is_number(n), do: "$#{n}"

  defp format_shares(nil), do: "—"
  defp format_shares(n) when n >= 1_000_000_000, do: "#{Float.round(n / 1_000_000_000, 2)}B"
  defp format_shares(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 2)}M"
  defp format_shares(n) when is_integer(n), do: Integer.to_string(n)
end
