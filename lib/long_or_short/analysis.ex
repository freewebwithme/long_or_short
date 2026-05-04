defmodule LongOrShort.Analysis do
  @moduledoc """
  Analysis domain — results of LLM-driven analyses of news articles.

  Each analysis type is its own resource (no polymorphic JSON blobs)
  to keep Ash validations, queries, and policies first-class. MVP
  ships `RepetitionAnalysis`; `PricePatternAnalysis` and
  `SynthesisAnalysis` will follow post-MVP.
  """

  use Ash.Domain, otp_app: :long_or_short

  resources do
    resource LongOrShort.Analysis.RepetitionAnalysis do
      define :start_repetition_analysis, action: :start, args: [:article_id]
      define :complete_repetition_analysis, action: :complete
      define :fail_repetition_analysis, action: :fail

      define :get_latest_repetition_analysis,
        action: :latest_for_article,
        args: [:article_id],
        get?: true,
        not_found_error?: false

      define :list_repetition_analyses_for_article,
        action: :for_article,
        args: [:article_id]

      define :get_pending_repetition_analysis,
        action: :pending_for_article,
        args: [:article_id],
        get?: true,
        not_found_error?: false
    end

    resource LongOrShort.Analysis.MomentumAnalysis do
      define :create_momentum_analysis, action: :create
      define :upsert_momentum_analysis, action: :upsert
      define :get_momentum_analysis, action: :read, get_by: [:id]

      define :get_momentum_analysis_by_article,
        action: :get_by_article,
        args: [:article_id],
        get?: true,
        not_found_error?: false

      define :destroy_momentum_analysis, action: :destroy
    end
  end
end
