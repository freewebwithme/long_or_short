defmodule LongOrShort.Analysis.Events do
  @moduledoc """
  PubSub wrapper for analysis pipeline events.

  Single source of truth for the topic name and message format.
  Mirrors `LongOrShort.News.Events`.

  ## Message format

      {:repetition_analysis_complete, %LongOrShort.Analysis.RepetitionAnalysis{}}
  """

  @topic "analysis_complete"

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(LongOrShort.PubSub, @topic)

  @spec broadcast_repetition_analysis_complete(LongOrShort.Analysis.RepetitionAnalysis.t()) ::
          :ok | {:error, term()}
  def broadcast_repetition_analysis_complete(analysis) do
    Phoenix.PubSub.broadcast(
      LongOrShort.PubSub,
      @topic,
      {:repetition_analysis_complete, analysis}
    )
  end
end
