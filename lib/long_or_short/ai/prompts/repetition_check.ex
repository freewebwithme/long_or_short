defmodule LongOrShort.AI.Prompts.RepetitionCheck do
  @moduledoc """
  Prompt builder for repetition analysis. Provider-agnostic.

  Returns a list of `t:LongOrShort.AI.Provider.message/0` messages that
  any provider can pass through.

  Pass an Article struct (or a plain map with the same fields). The
  Article must have its `:ticker` association loaded — the prompt
  references `article.ticker.symbol`.
  """

  @typedoc "Minimal article shape consumed by `build/2`."
  @type article :: %{
          required(:id) => String.t(),
          required(:title) => String.t(),
          required(:published_at) => DateTime.t(),
          optional(:summary) => String.t() | nil,
          optional(:ticker) => %{symbol: String.t()} | term()
        }

  @doc """
  Builds the messages list for repetition analysis.

  ## Examples

      iex> new_article = %{
      ...>   id: "11111111-1111-1111-1111-111111111111",
      ...>   title: "BTBD partners with Aero Velocity",
      ...>   summary: "Bit Digital announces new partnership.",
      ...>   published_at: ~U[2026-04-20 12:00:00Z],
      ...>   ticker: %{symbol: "BTBD"}
      ...> }
      iex> [%{role: "user", content: content}] =
      ...>   LongOrShort.AI.Prompts.RepetitionCheck.build(new_article, [])
      iex> String.contains?(content, "BTBD")
      true
      iex> String.contains?(content, "no past articles")
      true
  """
  @spec build(article(), [article()]) :: [LongOrShort.AI.Provider.message()]
  def build(new_article, past_articles) do
    [%{role: "user", content: render_user_message(new_article, past_articles)}]
  end

  defp render_user_message(new_article, past_articles) do
    """
    You are analyzing news for an active-trading decision-support tool.

    A new article has just arrived for ticker #{new_article.ticker.symbol}:

    NEW ARTICLE
    ID: #{new_article.id}
    Title: #{new_article.title}
    Summary: #{summary_or_blank(new_article)}
    Published: #{new_article.published_at}

    PAST ARTICLES (last 30 days, same ticker)
    #{format_past_articles(past_articles)}

    Determine whether the new article repeats a theme already covered in past articles.

    Guidelines:
    - "Repetition" means the same underlying theme/event type, not identical wording.
      Example: 4 different partnership announcements with different counterparties = repetition.
    - Count the new article itself in repetition_count. If this is the 4th occurrence, count = 4.
    - fatigue_level:
      * low: 1-2 occurrences (fresh)
      * medium: 3 occurrences
      * high: 4+ occurrences
    - related_article_ids: only include IDs of articles that share the same theme.
      Use the IDs exactly as shown above.

    Respond by calling the report_repetition_analysis tool. Do not respond in plain text.
    """
  end

  defp summary_or_blank(%{summary: summary}) when is_binary(summary) and summary != "",
    do: summary

  defp summary_or_blank(_), do: "(no summary)"

  defp format_past_articles([]), do: "(no past articles in last 30 days)"

  defp format_past_articles(articles) do
    articles
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {a, i} ->
      "#{i}. ID: #{a.id} | #{a.published_at} | #{a.title}"
    end)
  end
end
