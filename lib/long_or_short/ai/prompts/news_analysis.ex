defmodule LongOrShort.AI.Prompts.NewsAnalysis do
  @moduledoc """
  Prompt builder for news analysis. Provider-agnostic.

  Returns a list of `t:LongOrShort.AI.Provider.message/0` messages — one
  `system` (trader persona + behavior rules, derived from the user's
  `LongOrShort.Accounts.TradingProfile`) and one `user` (the article
  being analyzed plus optional past articles for repetition detection).

  Pair this with `LongOrShort.AI.Tools.NewsAnalysis.spec/0` and
  `LongOrShort.AI.Provider.call/3` to run an analysis. Persisting the
  result is `LongOrShort.Analysis.NewsAnalyzer`'s job (LON-82).

  ## Prompts in chat-style LLMs

  A prompt for a chat model is an ordered list of messages, each tagged
  with a role. Roles partition responsibility:

    * `system` — persona, style, rules. Read first; sets the model's
      behavior for the rest of the call. Stable across many calls for
      the same trader; varies across traders with different profiles.
    * `user` — the actual task input for this call. Changes per article.

  The model reads the messages in order and produces a response. With no
  tool spec attached, the response is free text. With a tool spec
  attached and the prompt's closing instruction `Do not respond in plain
  text`, the model returns a structured `tool_call` matching the spec
  instead — that's how `LongOrShort.AI.Tools.NewsAnalysis.spec/0` flows
  through to a writable `NewsAnalysis` row.

  Splitting persona from task data has two practical wins: providers can
  cache the system prefix across calls (cost + latency), and tweaking
  behavior doesn't risk corrupting per-article data.

  Anthropic's Messages API doesn't accept `role: "system"` inside the
  messages list — system content goes as a top-level `system` parameter.
  `LongOrShort.AI.Providers.Claude` extracts and routes it transparently
  so callers can pass system messages freely.

  ## Per-user personalization (LON-88)

  The system prompt is built from the caller-provided `TradingProfile`,
  not hardcoded. The persona intro and behavioral guidance branch on
  `:trading_style` (`:momentum_day`, `:swing`, `:large_cap_day`,
  `:position`, `:options`); structured fields (`:price_min/max`,
  `:float_max`) render only when present on the profile. This lets
  swing traders, large-cap day traders, etc. get analyses framed for
  their actual workflow instead of a one-size-fits-all small-cap
  scalper view.

  ## Past articles and repetition

  The user message includes a "PAST ARTICLES" block when `past_articles`
  is non-empty. The LLM uses that list to populate `repetition_count`
  and `repetition_summary` in its tool call — same theme, different
  wording counts as repetition.

  Phase 1 leans on the LLM to recognize repetition from raw history.
  Embedding-based pre-clustering (LON-40) is deferred until verdict
  quality on repetition proves it necessary.

  ## Article shape

  The article must have its `:ticker` association loaded — the prompt
  references `article.ticker.symbol`. See the `t:article/0` typespec
  for the exact required shape.
  """

  alias LongOrShort.Accounts.TradingProfile

  @typedoc """
  Minimal article shape consumed by `build/3`. Real `Article` structs
  satisfy this; tests can pass plain maps with the same keys.
  """
  @type article :: %{
          required(:title) => String.t(),
          required(:source) => atom() | String.t(),
          required(:published_at) => DateTime.t(),
          optional(:summary) => String.t() | nil,
          optional(:ticker) => %{symbol: String.t()} | term()
        }

  @doc """
  Builds the messages list for one news-analysis call.

  Returns `[system, user]`. Pair with the
  `LongOrShort.AI.Tools.NewsAnalysis.spec/0` tool and pass both to
  `LongOrShort.AI.Provider.call/3` — the model will invoke the tool
  with its analysis instead of replying in text.

  `profile` is a `LongOrShort.Accounts.TradingProfile` (or any struct
  with the same field shape — fixtures can use plain maps). The system
  prompt's persona, behavioral guidance, and structured-field section
  all derive from this profile.

  Pass `past_articles` (newest first) to give the LLM enough history to
  fill `repetition_count` and `repetition_summary`. Empty list is fine
  — the prompt will say so explicitly.

  ## Examples

      iex> profile = %{
      ...>   trading_style: :momentum_day,
      ...>   time_horizon: :intraday,
      ...>   market_cap_focuses: [:micro, :small],
      ...>   catalyst_preferences: [:partnership, :fda],
      ...>   notes: nil,
      ...>   price_min: Decimal.new("2.0"),
      ...>   price_max: Decimal.new("10.0"),
      ...>   float_max: 50_000_000
      ...> }
      iex> article = %{
      ...>   title: "BTBD partners with Aero Velocity",
      ...>   summary: "Bit Digital announces partnership.",
      ...>   source: :finnhub,
      ...>   published_at: ~U[2026-04-20 12:00:00Z],
      ...>   ticker: %{symbol: "BTBD"}
      ...> }
      iex> [system, user] =
      ...>   LongOrShort.AI.Prompts.NewsAnalysis.build(article, [], profile)
      iex> system.role
      "system"
      iex> String.contains?(system.content, "small-cap momentum day trader")
      true
      iex> String.contains?(system.content, "$2") and String.contains?(system.content, "$10")
      true
      iex> String.contains?(user.content, "BTBD")
      true
      iex> String.contains?(user.content, "no past articles")
      true
  """
  @spec build(article(), [article()], TradingProfile.t() | map()) ::
          [LongOrShort.AI.Provider.message()]
  def build(article, past_articles, profile) do
    [
      %{role: "system", content: render_system_prompt(profile)},
      %{role: "user", content: render_user_message(article, past_articles)}
    ]
  end

  # ─── System prompt ─────────────────────────────────────────────────

  defp render_system_prompt(profile) do
    """
    You are a trader's analyst, not a research desk. Your job is to read one
    news headline + summary and produce a trading assessment by calling
    the `record_news_analysis` tool.

    You are supporting a #{persona_intro(profile.trading_style)}.

    Trader profile:
    #{render_profile_lines(profile)}

    #{behavioral_guidance(profile.trading_style)}
    Speak like a trader, not a research analyst. Korean is welcome where
    natural — the trader is bilingual.
    #{render_notes(profile.notes)}
    Always respond by calling the `record_news_analysis` tool. Do not
    respond in plain text.
    """
  end

  defp persona_intro(:momentum_day), do: "small-cap momentum day trader"
  defp persona_intro(:large_cap_day), do: "large-cap day trader"
  defp persona_intro(:swing), do: "swing trader (multi-day to multi-week holds)"
  defp persona_intro(:position), do: "position investor (multi-week to multi-month holds)"
  defp persona_intro(:options), do: "options trader"

  defp behavioral_guidance(:momentum_day) do
    """
    Be honest about weak catalysts (vague RFPs, generic partnerships,
    recycled themes) and direct about strong ones (FDA approvals, M&A,
    contract wins with named counterparties). Call out fade risk
    explicitly when you see it. 5-minute scalp mindset.
    """
  end

  defp behavioral_guidance(:swing) do
    """
    Focus on multi-day continuation potential, not intraday volatility.
    Identify entry windows over the next 1–3 sessions. Distinguish
    gap-and-go from gap-and-fade.
    """
  end

  defp behavioral_guidance(:large_cap_day) do
    """
    Treat the catalyst against the stock's typical reaction range. 1–3%
    moves are normal for large caps — call out when the expected move
    exceeds that. Watch for institutional flow signals (block trades,
    options activity).
    """
  end

  defp behavioral_guidance(:position) do
    """
    Frame the news against the long-term thesis. Distinguish
    thesis-changing events from noise. Don't optimize for entry timing
    — focus on whether to add, hold, or trim.
    """
  end

  defp behavioral_guidance(:options) do
    """
    Highlight implied volatility implications and event-driven option
    strategies. Note expected move vs realized move for upcoming events.
    """
  end

  # ─── Profile rendering ─────────────────────────────────────────────

  defp render_profile_lines(profile) do
    base_lines = [
      "  * Style: #{profile.trading_style}",
      "  * Time horizon: #{profile.time_horizon}",
      "  * Market cap focus: #{format_market_caps(profile.market_cap_focuses)}",
      "  * Catalyst preferences: #{format_catalysts(profile.catalyst_preferences)}"
    ]

    style_lines =
      [
        price_band_line(profile),
        float_line(profile)
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(base_lines ++ style_lines, "\n")
  end

  defp format_market_caps([]), do: "any"
  defp format_market_caps(focuses), do: Enum.join(focuses, ", ")

  defp format_catalysts([]), do: "any"
  defp format_catalysts(prefs), do: Enum.join(prefs, ", ")

  defp price_band_line(%{price_min: min, price_max: max})
       when not is_nil(min) and not is_nil(max),
       do: "  * Stocks priced $#{min}–$#{max}"

  defp price_band_line(_), do: nil

  defp float_line(%{float_max: max}) when not is_nil(max),
    do: "  * Float under #{format_shares(max)}"

  defp float_line(_), do: nil

  defp format_shares(n) when n >= 1_000_000_000, do: "#{div(n, 1_000_000_000)}B"
  defp format_shares(n) when n >= 1_000_000, do: "#{div(n, 1_000_000)}M"
  defp format_shares(n), do: to_string(n)

  defp render_notes(nil), do: ""
  defp render_notes(""), do: ""
  defp render_notes(notes), do: "\nAdditional notes:\n#{notes}\n"

  # ─── User message (article + past articles) ────────────────────────

  defp render_user_message(article, past_articles) do
    """
    Ticker: #{article.ticker.symbol}
    Source: #{article.source}
    Published: #{article.published_at}

    Headline: #{article.title}

    Summary:
    #{summary_or_blank(article)}

    PAST ARTICLES (same ticker, recent first)
    #{format_past_articles(past_articles)}

    Guidelines:
      * "Repetition" means the same underlying theme/event, not identical wording.
        Example: 4 different partnership announcements with different counterparties = repetition_count 4.
      * Count the new article in repetition_count. First occurrence = 1.
      * When repetition_count > 1, fill repetition_summary with a short cluster label.
      * Be specific in detail sections — bullet lists, not paragraphs.

    Respond by calling the record_news_analysis tool. Do not respond in plain text.
    """
  end

  defp summary_or_blank(%{summary: summary}) when is_binary(summary) and summary != "",
    do: summary

  defp summary_or_blank(_), do: "(no summary)"

  defp format_past_articles([]), do: "(no past articles in window)"

  defp format_past_articles(articles) do
    Enum.map_join(articles, "\n", fn a -> "- #{a.published_at} | #{a.title}" end)
  end
end
