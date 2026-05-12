defmodule LongOrShort.News do
  @moduledoc """
  News domain — articles collected from external sources.

  Feeders (Benzinga, SEC, PR Newswire) ingest into this domain via
  `ingest_article/2`. Analysis results and price reactions live in
  their own domains but reference articles by id.

  Raw API payloads are preserved cold in `LongOrShort.News.ArticleRaw`
  (table `articles_raw`) so debugging / re-analysis / source-bug forensics
  can reach ground truth (LON-32). Populated fail-soft by
  `Sources.Pipeline` after each successful article ingest.
  """

  use Ash.Domain, otp_app: :long_or_short

  resources do
    resource LongOrShort.News.Article do
      define :create_article, action: :create
      define :ingest_article, action: :ingest
      define :create_manual_article, action: :create_manual
      define :get_article, action: :read, get_by: [:id]
      define :list_articles, action: :read
      define :list_articles_by_ticker, action: :by_ticker, args: [:ticker_id]
      define :list_recent_articles, action: :recent
      define :list_morning_brief, action: :morning_brief
      define :destroy_article, action: :destroy

      define :get_article_content_hash,
        action: :get_content_hash,
        args: [:source, :external_id, :symbol]

      define :list_recent_articles_for_ticker,
        action: :recent_for_ticker,
        args: [:ticker_id, :since]

      define :list_recent_articles_for_tickers,
        action: :recent_for_tickers,
        args: [:ticker_ids]

      define :list_articles_by_ticker_symbol, action: :by_ticker_symbol, args: [:symbol]
    end

    resource LongOrShort.News.ArticleRaw do
      define :create_article_raw, action: :create
      define :get_article_raw, action: :read, get_by: [:article_id]
      define :destroy_article_raw, action: :destroy
    end
  end
end
