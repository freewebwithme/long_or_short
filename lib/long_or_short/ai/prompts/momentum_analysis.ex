defmodule LongOrShort.AI.Prompts.MomentumAnalysis do
  @moduledoc """
  Prompt builder for momentum analysis. Provider-agnostic.

  Returns a list of `t:LongOrShort.AI.Provider.message/0` messages — one
  `system` (trader persona + behavior rules, stable across calls) and one
  `user` (the article being analyzed plus optional past articles for
  repetition detection).

  Pair this with `LongOrShort.AI.Tools.MomentumAnalysis.spec/0` (LON-81)
  and `LongOrShort.AI.Provider.call/3` to run an analysis. Persisting the
  result is `LongOrShort.Analysis.MomentumAnalyzer`'s job (LON-82).

  ## Prompts in chat-style LLMs

  A prompt for a chat model is an ordered list of messages, each tagged
  with a role. Roles partition responsibility:

    * `system` — persona, style, rules. Read first; sets the model's
      behavior for the rest of the call. Stable across many calls —
      same trader, same instructions, different articles.
    * `user` — the actual task input for this call. Changes per article.

  The model reads the messages in order and produces a response. With no
  tool spec attached, the response is free text. With a tool spec
  attached and the prompt's closing instruction `Do not respond in plain
  text`, the model returns a structured `tool_call` matching the spec
  instead — that's how `LongOrShort.AI.Tools.MomentumAnalysis.spec/0`
  flows through to a writable `MomentumAnalysis` row.

  Splitting persona from task data has two practical wins: providers can
  cache the system prefix across calls (cost + latency), and tweaking
  behavior doesn't risk corrupting per-article data.

  Anthropic's Messages API doesn't accept `role: "system"` inside the
  messages list — system content goes as a top-level `system` parameter.
  `LongOrShort.AI.Providers.Claude` extracts and routes it transparently
  so callers can pass system messages freely.

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

  ## Future: per-user trader profile

  The current system prompt hardcodes one trader's profile (price band,
  float ceiling, RVOL minimum, hold style). LON-88 replaces this with a
  per-user `TradingProfile` Ash resource so analyses match each
  trader's actual style. `build/2` will gain a profile parameter then.
  """

  @typedoc """
  Minimal article shape consumed by `build/2`. Real `Article` structs
  satisfy this; tests can pass plain maps with the same keys.
  """
  @type article :: %{
          required(:title) => String.t(),
          required(:source) => atom() | String.t(),
          required(:published_at) => DateTime.t(),
          optional(:summary) => String.t() | nil,
          optional(:ticker) => %{symbol: String.t()} | term()
        }

  @system_prompt """
  You are a trader's analyst, not a research desk. Your job is to read one
  news headline + summary and produce a momentum-trading assessment by
  calling the `record_momentum_analysis` tool.

  Trader profile:
    * Stocks priced $2–$10
    * Float under 50M shares
    * Relative volume 200%+
    * 5-minute scalp entries on news catalysts
    * Watches for spike-then-fade patterns and exits fast

  Be honest about weak catalysts (vague RFPs, generic partnerships,
  recycled themes) and direct about strong ones (FDA approvals, M&A,
  contract wins with named counterparties). Call out fade risk
  explicitly when you see it.

  Speak like a trader, not a research analyst. Korean is welcome where
  natural — the trader is bilingual.

  Always respond by calling the `record_momentum_analysis` tool. Do not
  respond in plain text.
  """

  @doc """
  Builds the messages list for one momentum-analysis call.

  Returns `[system, user]`. Pair with the
  `LongOrShort.AI.Tools.MomentumAnalysis.spec/0` tool and pass both to
  `LongOrShort.AI.Provider.call/3` — the model will invoke the tool
  with its analysis instead of replying in text.

  Pass `past_articles` (newest first) to give the LLM enough history to
  fill `repetition_count` and `repetition_summary`. Empty list is fine
  — the prompt will say so explicitly.

  ## Examples

      iex> article = %{
      ...>   title: "BTBD partners with Aero Velocity",
      ...>   summary: "Bit Digital announces partnership.",
      ...>   source: :finnhub,
      ...>   published_at: ~U[2026-04-20 12:00:00Z],
      ...>   ticker: %{symbol: "BTBD"}
      ...> }
      iex> [system, user] = LongOrShort.AI.Prompts.MomentumAnalysis.build(article)
      iex> system.role
      "system"
      iex> user.role
      "user"
      iex> String.contains?(user.content, "BTBD")
      true
      iex> String.contains?(user.content, "no past articles")
      true
  """
  @spec build(article(), [article()]) :: [LongOrShort.AI.Provider.message()]
  def build(article, past_articles \\ []) do
    [
      %{role: "system", content: @system_prompt},
      %{role: "user", content: render_user_message(article, past_articles)}
    ]
  end

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

    Respond by calling the record_momentum_analysis tool. Do not respond in plain text.
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
