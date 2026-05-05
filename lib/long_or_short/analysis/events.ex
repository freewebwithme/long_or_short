defmodule LongOrShort.Analysis.Events do
  @moduledoc """
  PubSub wrapper for analysis pipeline events.

  Single source of truth for the topic name and message format.
  Mirrors `LongOrShort.News.Events`.

  Currently exposes only `subscribe/0` so subscribers can register
  early. Broadcast functions for the new `NewsAnalysis` lifecycle land
  with `LongOrShort.Analysis.NewsAnalyzer` (LON-82); until then no
  events are published on this topic.
  """

  @topic "analysis_complete"

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(LongOrShort.PubSub, @topic)
end
