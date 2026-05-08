defmodule LongOrShort.Analysis do
  @moduledoc """
  Analysis domain — results of LLM-driven analyses of news articles.

  Each analysis type is its own resource (no polymorphic JSON blobs)
  to keep Ash validations, queries, and policies first-class. Currently
  ships `NewsAnalysis` (LON-78 epic — comprehensive multi-signal card).
  Future analysis types (e.g. `PricePatternAnalysis`,
  `SynthesisAnalysis`) get their own resources alongside.
  """

  use Ash.Domain, otp_app: :long_or_short

  resources do
    resource LongOrShort.Analysis.NewsAnalysis do
      define :create_news_analysis, action: :create
      define :upsert_news_analysis, action: :upsert
      define :get_news_analysis, action: :read, get_by: [:id]

      define :get_news_analysis_by_article,
        action: :get_by_article,
        args: [:article_id],
        get?: true,
        not_found_error?: false

      define :list_recent_analyses, action: :recent
      define :destroy_news_analysis, action: :destroy
    end
  end
end
