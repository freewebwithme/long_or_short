defmodule LongOrShort.Analysis.Events do
  @moduledoc """
  PubSub wrapper for analysis pipeline events.

  Single source of truth for topic strings and message formats.
  Mirrors `LongOrShort.News.Events`.

  ## Topics

    * `"analysis_complete"` — legacy global topic. Subscribed by `/feed`
      and dashboard via `subscribe/0` from the RepetitionAnalysis era;
      no producer publishes to it today. Will be removed in LON-83
      when those LiveViews switch to article-scoped subscriptions.

    * `"analysis:article:<article_id>"` — per-article topic, used by
      `LongOrShort.Analysis.NewsAnalyzer` (LON-82) to broadcast a
      single `{:news_analysis_ready, %NewsAnalysis{}}` message after
      the upsert succeeds. Article-scoped so a LiveView subscribes
      only to the article it's currently displaying — no need to fan
      every analysis out to every connected client.
  """

  alias LongOrShort.Analysis.NewsAnalysis

  @global_topic "analysis_complete"
  @article_topic_prefix "analysis:article:"

  @doc """
  Subscribe to the legacy global topic. Kept for backward compatibility
  with the `/feed` and dashboard LiveViews; no producer publishes here
  today. LON-83 removes this once those LiveViews adopt
  `subscribe_for_article/1`.
  """
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(LongOrShort.PubSub, @global_topic)

  @doc """
  Subscribe to the analysis topic for a specific article. The caller
  receives `{:news_analysis_ready, %NewsAnalysis{}}` when an analysis
  for that article is persisted.
  """
  @spec subscribe_for_article(String.t()) :: :ok | {:error, term()}
  def subscribe_for_article(article_id) when is_binary(article_id) do
    Phoenix.PubSub.subscribe(LongOrShort.PubSub, @article_topic_prefix <> article_id)
  end

  @doc """
  Broadcast a successful analysis on the article-scoped topic.
  Called by `LongOrShort.Analysis.NewsAnalyzer.analyze/2` after the
  upsert succeeds — never call directly from LiveViews.
  """
  @spec broadcast_analysis_ready(NewsAnalysis.t()) :: :ok | {:error, term()}
  def broadcast_analysis_ready(%NewsAnalysis{} = analysis) do
    Phoenix.PubSub.broadcast(
      LongOrShort.PubSub,
      @article_topic_prefix <> analysis.article_id,
      {:news_analysis_ready, analysis}
    )
  end
end
