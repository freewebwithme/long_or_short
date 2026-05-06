defmodule LongOrShort.News do
  @moduledoc """
  News domain — articles collected from external sources.

  Feeders (Benzinga, SEC, PR Newswire) ingest into this domain via
  `ingest_article/2`. Analysis results and price reactions live in
  their own domains but reference articles by id.
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
  end
end
