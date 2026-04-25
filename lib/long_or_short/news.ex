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
      define :get_article, action: :read, get_by: [:id]
      define :list_articles, action: :read
      define :list_articles_by_ticker, action: :by_ticker, args: [:ticker_id]
      define :list_recent_articles, action: :recent
      define :destroy_article, action: :destroy
    end
  end
end
