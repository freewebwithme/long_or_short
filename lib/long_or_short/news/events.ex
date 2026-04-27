defmodule LongOrShort.News.Events do
  @moduledoc """
  Standardized PubSub interface for the news pipeline.

  Centralizes the topic name and message format so callers (Pipeline,
  LiveView, future manual paste form, AI analysis pipeline) all go
  through one place. If the topic ever needs to be renamed or sharded
  by ticker, this is the only module that changes.

  ## Message format

      {:new_article, %LongOrShort.News.Article{}}

  Receivers pattern-match the tuple directly. The Article struct is
  passed in full (not just an id) so LiveViews can render immediately
  without a round-trip to the DB.
  """

  @topic "news:articles"

  @doc """
  Subscribe the calling process to new-article events.

  After this returns, messages of the form
  `{:new_article, %Article{}}` will arrive in the process's mailbox.
  """
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    Phoenix.PubSub.subscribe(LongOrShort.PubSub, @topic)
  end

  @doc """
  Broadcast a newly-ingested article to all subscribers.
  """
  @spec broadcast_new_article(LongOrShort.News.Article.t()) :: :ok | {:error, term()}
  def broadcast_new_article(article) do
    Phoenix.PubSub.broadcast(
      LongOrShort.PubSub,
      @topic,
      {:new_article, article}
    )
  end
end
