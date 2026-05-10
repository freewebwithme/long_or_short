defmodule LongOrShort.Filings.Events do
  @moduledoc """
  PubSub wrapper for filings analysis pipeline events.

  Single source of truth for topic strings and message formats.
  Mirrors `LongOrShort.Analysis.Events` and `LongOrShort.News.Events`.

  ## Topics

    * `"filings:analyses"` — global topic for new `FilingAnalysis` rows
      produced by `LongOrShort.Filings.Analyzer` (LON-115, Stage 3c).
      Each persisted analysis broadcasts
      `{:new_filing_analysis, %FilingAnalysis{}}`. Stage 7 alerts and
      the future dilution-profile UI both subscribe here.

  ## Why a global topic, not per-filing

  Unlike `NewsAnalysis` (per-article subscription matches the
  `/analyze/:id` page), the dilution UX wants "show me every new
  dilution analysis as it lands" — Stage 7 alerts fan watchlist hits
  out to traders, and the dilution profile UI shows recent activity
  across all watched tickers. One global topic + per-subscriber
  filtering by ticker is simpler than asking every subscriber to
  subscribe to every filing-id topic separately.

  If a future page genuinely wants single-filing scope, add a
  `"filings:filing:<filing_id>"` topic alongside this one — don't
  retrofit the global topic.
  """

  alias LongOrShort.Filings.FilingAnalysis

  @global_topic "filings:analyses"

  @doc """
  Subscribe to the global filings analysis topic. The caller receives
  `{:new_filing_analysis, %FilingAnalysis{}}` for every persisted
  analysis, regardless of which trigger path produced it (watchlist
  worker, backfill worker, manual trigger).
  """
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(LongOrShort.PubSub, @global_topic)

  @doc """
  Broadcast a freshly persisted `FilingAnalysis`. Called by
  `LongOrShort.Filings.Analyzer.analyze_filing/2` after the upsert
  succeeds — never call directly from LiveViews or workers.
  """
  @spec broadcast_analysis_ready(FilingAnalysis.t()) :: :ok | {:error, term()}
  def broadcast_analysis_ready(%FilingAnalysis{} = analysis) do
    Phoenix.PubSub.broadcast(
      LongOrShort.PubSub,
      @global_topic,
      {:new_filing_analysis, analysis}
    )
  end
end
