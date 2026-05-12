defmodule LongOrShort.NewsFixtures do
  @moduledoc """
  Test fixtures for the News domain.
  """

  alias LongOrShort.News

  @doc """
  Returns a map of valid attributes for ingesting an article.
  Symbol and external_id auto-generated to avoid collisions.
  """
  def valid_article_attrs(overrides \\ %{}) do
    unique = System.unique_integer([:positive])

    Map.merge(
      %{
        symbol: "ART#{unique}",
        source: :benzinga,
        external_id: "ext-#{unique}",
        title: "Test Headline #{unique}",
        summary: "Test summary body.",
        url: "https://example.com/articles/#{unique}",
        published_at: DateTime.utc_now(),
        raw_category: "General",
        sentiment: :unknown
      },
      overrides
    )
  end

  @doc """
  Creates an Article via the :ingest action (which auto-creates the
  Ticker if needed). Use when the test does not care about the ticker
  resolution path.
  """
  def build_article(overrides \\ %{}) do
    attrs = valid_article_attrs(overrides)

    case News.ingest_article(attrs, authorize?: false) do
      {:ok, article} ->
        article

      {:error, error} ->
        raise """
        Failed to create article fixture.
        attrs: #{inspect(attrs)}
        error: #{inspect(error)}
        """
    end
  end

  @doc """
  Returns a map of valid attributes for the :create_manual action.
  Notably omits `external_id` (the action generates one) and
  `sentiment` (not accepted — manual paste defaults to :unknown).
  """
  def valid_manual_article_attrs(overrides \\ %{}) do
    unique = System.unique_integer([:positive])

    Map.merge(
      %{
        symbol: "MAN#{unique}",
        source: :benzinga,
        title: "Manual Headline #{unique}",
        summary: "Pasted body text.",
        url: "https://example.com/manual/#{unique}",
        raw_category: "General",
        published_at: DateTime.utc_now()
      },
      overrides
    )
  end

  @doc """
  Creates an Article for an existing Ticker via the :create action
  (no ticker resolution). Useful for tests that have already set up
  a Ticker and want to attach articles to it.
  """
  def build_article_for_ticker(ticker, overrides \\ %{}) do
    unique = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{
          source: :benzinga,
          external_id: "ext-#{unique}",
          title: "Test Headline #{unique}",
          summary: "Test summary.",
          url: "https://example.com/articles/#{unique}",
          published_at: DateTime.utc_now(),
          ticker_id: ticker.id
        },
        overrides
      )

    case News.create_article(attrs, authorize?: false) do
      {:ok, article} ->
        article

      {:error, error} ->
        raise """
        Failed to create article fixture for ticker.
        attrs: #{inspect(attrs)}
        error: #{inspect(error)}
        """
    end
  end

  @doc """
  Returns valid attrs for `News.create_article_raw/2`. `:article_id` is
  intentionally omitted — callers supply it from a fixture-built Article.
  """
  def valid_article_raw_attrs(overrides \\ %{}) do
    unique = System.unique_integer([:positive])

    Map.merge(
      %{
        raw_payload: %{"id" => unique, "headline" => "Raw payload #{unique}"}
      },
      overrides
    )
  end

  @doc """
  Creates an ArticleRaw attached to the given Article. Mirrors
  `build_filing_raw/2` in the Filings fixtures.
  """
  def build_article_raw(article, overrides \\ %{}) do
    attrs =
      valid_article_raw_attrs(overrides)
      |> Map.put(:article_id, article.id)

    case News.create_article_raw(attrs, authorize?: false) do
      {:ok, raw} ->
        raw

      {:error, error} ->
        raise """
        Failed to create article_raw fixture.
        attrs: #{inspect(attrs)}
        error: #{inspect(error)}
        """
    end
  end
end
