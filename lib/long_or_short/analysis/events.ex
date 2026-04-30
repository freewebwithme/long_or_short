defmodule LongOrShort.Analysis.Events do
  @moduledoc """
  PubSub wrapper for analysis pipeline events.

  Single source of truth for the topic name and message format.
  Mirrors `LongOrShort.News.Events`.

  ## Message format

       {:repetition_analysis_started, %LongOrShort.Analysis.RepetitionAnalysis{}}
       {:repetition_analysis_complete, %LongOrShort.Analysis.RepetitionAnalysis{}}
       {:repetition_analysis_failed,   %LongOrShort.Analysis.RepetitionAnalysis{}}
  """

  alias LongOrShort.Analysis.RepetitionAnalysis

  @topic "analysis_complete"

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(LongOrShort.PubSub, @topic)

  @spec broadcast_repetition_analysis_started(RepetitionAnalysis.t()) :: :ok | {:error, term()}
  def broadcast_repetition_analysis_started(analysis) do
    broadcast({:repetition_analysis_started, analysis})
  end

  @spec broadcast_repetition_analysis_complete(LongOrShort.Analysis.RepetitionAnalysis.t()) ::
          :ok | {:error, term()}
  def broadcast_repetition_analysis_complete(analysis) do
    broadcast({:repetition_analysis_complete, analysis})
  end

  @spec broadcast_repetition_analysis_failed(RepetitionAnalysis.t()) ::
          :ok | {:error, term()}
  def broadcast_repetition_analysis_failed(analysis) do
    broadcast({:repetition_analysis_failed, analysis})
  end

  defp broadcast(message) do
    Phoenix.PubSub.broadcast(
      LongOrShort.PubSub,
      @topic,
      message
    )
  end
end
