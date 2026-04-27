defmodule LongOrShort.News.ArticleTest do
  @moduledoc """
  Unit tests for `LongOrShort.News.Article`.

  Organized by action, with separate blocks for the `:ingest` auto-upsert
  behavior, the ComputeContentHash change, and policies.
  """

  use LongOrShort.DataCase, async: true

  import LongOrShort.{NewsFixtures, AccountsFixtures}

  alias LongOrShort.News
  alias LongOrShort.Tickers

  describe "create_article/2" do
    test "creates an article when given an existing ticker_id" do
      ticker = build_ticker(%{symbol: "AAPL"})

      {:ok, article} =
        News.create_article(
          %{
            source: :benzinga,
            external_id: "ext-1",
            title: "Apple beats earnings",
            summary: "Q3 results exceed expectations.",
            url: "https://example.com/aapl",
            published_at: DateTime.utc_now(),
            ticker_id: ticker.id
          },
          authorize?: false
        )

      assert article.ticker_id == ticker.id
      assert article.source == :benzinga
      assert article.external_id == "ext-1"
      assert article.title == "Apple beats earnings"
      assert %DateTime{} = article.published_at
      assert %DateTime{} = article.fetched_at
    end

    test "requires title, source, external_id, published_at, ticker_id" do
      ticker = build_ticker()

      base = %{
        source: :benzinga,
        external_id: "ext-base",
        title: "T",
        published_at: DateTime.utc_now(),
        ticker_id: ticker.id
      }

      for {field, _} <- base do
        attrs = Map.delete(base, field)

        assert {:error, %Ash.Error.Invalid{} = error} =
                 News.create_article(attrs, authorize?: false),
               "expected error when missing #{field}"

        assert error_on_field?(error, field)
      end
    end

    test "rejects unknown source value" do
      ticker = build_ticker()

      assert {:error, %Ash.Error.Invalid{} = error} =
               News.create_article(
                 %{
                   source: :reuters,
                   external_id: "ext-x",
                   title: "T",
                   published_at: DateTime.utc_now(),
                   ticker_id: ticker.id
                 },
                 authorize?: false
               )

      assert error_on_field?(error, :source)
    end

    test "rejects unknown sentiment value" do
      ticker = build_ticker()

      assert {:error, %Ash.Error.Invalid{} = error} =
               News.create_article(
                 %{
                   source: :benzinga,
                   external_id: "ext-x",
                   title: "T",
                   published_at: DateTime.utc_now(),
                   ticker_id: ticker.id,
                   sentiment: :euphoric
                 },
                 authorize?: false
               )

      assert error_on_field?(error, :sentiment)
    end

    test "defaults sentiment to :unknown" do
      ticker = build_ticker()

      {:ok, article} =
        News.create_article(
          %{
            source: :benzinga,
            external_id: "ext-default",
            title: "T",
            published_at: DateTime.utc_now(),
            ticker_id: ticker.id
          },
          authorize?: false
        )

      assert article.sentiment == :unknown
    end
  end

  describe "ingest_article/2" do
    test "creates the ticker when symbol does not exist yet" do
      assert {:error, _} = Tickers.get_ticker_by_symbol("NEWCO", authorize?: false)

      {:ok, article} =
        News.ingest_article(valid_article_attrs(%{symbol: "NEWCO"}), authorize?: false)

      {:ok, ticker} =
        Tickers.get_ticker_by_symbol("NEWCO", authorize?: false)

      assert article.ticker_id == ticker.id
    end

    test "reuses the existing ticker when symbol matches" do
      existing = build_ticker(%{symbol: "EXISTS"})

      {:ok, article} =
        News.ingest_article(
          valid_article_attrs(%{symbol: "EXISTS"}),
          authorize?: false
        )

      assert article.ticker_id == existing.id
    end

    test "normalizes lowercase symbol via Ticker upsert" do
      {:ok, article} =
        News.ingest_article(
          valid_article_attrs(%{symbol: "btbd"}),
          authorize?: false
        )

      {:ok, ticker} =
        Tickers.get_ticker_by_symbol("BTBD", authorize?: false)

      assert article.ticker_id == ticker.id
    end

    test "is idempotent on (source, external_id, symbol)" do
      attrs =
        valid_article_attrs(%{
          symbol: "IDEMP",
          source: :benzinga,
          external_id: "duplicate-1"
        })

      {:ok, first} = News.ingest_article(attrs, authorize?: false)
      {:ok, second} = News.ingest_article(attrs, authorize?: false)

      assert first.id == second.id
    end

    test "overwrites content fields on re-ingest (last-writer-wins)" do
      base =
        valid_article_attrs(%{
          symbol: "UPDATED",
          source: :benzinga,
          external_id: "updated-1",
          title: "Original title",
          summary: "Original summary",
          sentiment: :positive
        })

      {:ok, first} = News.ingest_article(base, authorize?: false)

      {:ok, second} =
        News.ingest_article(
          Map.merge(base, %{
            title: "Revised title",
            summary: "Revised summary",
            sentiment: :negative
          }),
          authorize?: false
        )

      assert first.id == second.id
      assert second.title == "Revised title"
      assert second.summary == "Revised summary"
      assert second.sentiment == :negative
      # content_hash must track title/summary changes
      refute first.content_hash == second.content_hash
    end

    test "preserves published_at and fetched_at on re-ingest" do
      original_published = ~U[2026-04-20 12:00:00.000000Z]

      base =
        valid_article_attrs(%{
          symbol: "STABLE",
          source: :benzinga,
          external_id: "stable-1",
          published_at: original_published
        })

      {:ok, first} = News.ingest_article(base, authorize?: false)

      {:ok, second} =
        News.ingest_article(
          Map.put(base, :published_at, ~U[2026-04-21 09:00:00.000000Z]),
          authorize?: false
        )

      assert first.id == second.id
      assert DateTime.compare(second.published_at, original_published) == :eq
      assert DateTime.compare(second.fetched_at, first.fetched_at) == :eq
    end

    test "creates separate rows when same external_id is used for different tickers" do
      # Source feeders split multi-ticker articles into one row per ticker.
      # Identity is (source, external_id, ticker_id), so the same external_id
      # paired with different tickers must coexist.
      shared_external_id = "multi-#{System.unique_integer([:positive])}"

      {:ok, art1} =
        News.ingest_article(
          valid_article_attrs(%{
            symbol: "MULTI1",
            source: :benzinga,
            external_id: shared_external_id
          }),
          authorize?: false
        )

      {:ok, art2} =
        News.ingest_article(
          valid_article_attrs(%{
            symbol: "MULTI2",
            source: :benzinga,
            external_id: shared_external_id
          }),
          authorize?: false
        )

      refute art1.id == art2.id
      refute art1.ticker_id == art2.ticker_id
    end
  end

  describe "uniqueness" do
    test "create_article rejects duplicate (source, external_id, ticker_id)" do
      ticker = build_ticker(%{symbol: "DUP"})

      attrs = %{
        source: :benzinga,
        external_id: "dup-1",
        title: "First",
        published_at: DateTime.utc_now(),
        ticker_id: ticker.id
      }

      {:ok, _} = News.create_article(attrs, authorize?: false)

      assert {:error, %Ash.Error.Invalid{}} =
               News.create_article(attrs, authorize?: false)
    end
  end

  describe "content_hash" do
    test "computes a hash fro mtitle and summary on create" do
      ticker = build_ticker()

      {:ok, article} =
        News.create_article(
          %{
            source: :benzinga,
            external_id: "h-1",
            title: "Hello",
            summary: "World",
            published_at: DateTime.utc_now(),
            ticker_id: ticker.id
          },
          authorize?: false
        )

      assert is_binary(article.content_hash)
      # sha256 hex
      assert String.length(article.content_hash) == 64
    end

    test "produces same has for identical title+summary" do
      ticker_a = build_ticker(%{symbol: "HASHA"})
      ticker_b = build_ticker(%{symbol: "HASHB"})

      attrs_template = fn ticker, ext_id ->
        %{
          source: :benzinga,
          external_id: ext_id,
          title: "Same Title",
          summary: "Same Summary",
          published_at: DateTime.utc_now(),
          ticker_id: ticker.id
        }
      end

      {:ok, a} =
        News.create_article(attrs_template.(ticker_a, "a"), authorize?: false)

      {:ok, b} =
        News.create_article(attrs_template.(ticker_b, "b"), authorize?: false)

      assert a.content_hash == b.content_hash
    end

    test "produces different hash when title differs" do
      ticker = build_ticker()

      {:ok, a} =
        News.create_article(
          %{
            source: :benzinga,
            external_id: "diff-a",
            title: "Title A",
            summary: "Body",
            published_at: DateTime.utc_now(),
            ticker_id: ticker.id
          },
          authorize?: false
        )

      {:ok, b} =
        News.create_article(
          %{
            source: :benzinga,
            external_id: "diff-b",
            title: "Title B",
            summary: "Body",
            published_at: DateTime.utc_now(),
            ticker_id: ticker.id
          },
          authorize?: false
        )

      refute a.content_hash == b.content_hash
    end

    test "handles nil summary gracefully (e.g. SEC filings)" do
      ticker = build_ticker()

      {:ok, article} =
        News.create_article(
          %{
            source: :sec,
            external_id: "sec-1",
            title: "8-K filing",
            summary: nil,
            published_at: DateTime.utc_now(),
            ticker_id: ticker.id
          },
          authorize?: false
        )

      assert is_binary(article.content_hash)
    end
  end

  describe "list_articles_by_ticker/2" do
    test "returns articles for the given ticker, newest first" do
      ticker = build_ticker(%{symbol: "TIM"})
      other = build_ticker(%{symbol: "OTHER"})

      now = DateTime.utc_now()
      older = DateTime.add(now, -3600, :second)

      _newest = build_article_for_ticker(ticker, %{published_at: now})
      _oldest = build_article_for_ticker(ticker, %{published_at: older})
      _excluded = build_article_for_ticker(other)

      {:ok, articles} =
        News.list_articles_by_ticker(ticker.id, authorize?: false)

      assert length(articles) == 2
      assert Enum.all?(articles, &(&1.ticker_id == ticker.id))

      [first, second] = articles
      assert DateTime.compare(first.published_at, second.published_at) == :gt
    end

    test "returns empty list when ticker has no articles" do
      ticker = build_ticker()

      {:ok, articles} =
        News.list_articles_by_ticker(ticker.id, authorize?: false)

      assert articles == []
    end
  end

  describe "list_recent_articles/1" do
    test "returns articles sorted by published_at descending" do
      ticker = build_ticker()
      now = DateTime.utc_now()

      build_article_for_ticker(ticker, %{
        published_at: DateTime.add(now, -7200, :second)
      })

      build_article_for_ticker(ticker, %{published_at: now})

      build_article_for_ticker(ticker, %{
        published_at: DateTime.add(now, -3600, :second)
      })

      {:ok, [first, second, third]} =
        News.list_recent_articles(authorize?: false)

      assert DateTime.compare(first.published_at, second.published_at) == :gt
      assert DateTime.compare(second.published_at, third.published_at) == :gt
    end

    test "respects limit argument" do
      ticker = build_ticker()
      for _ <- 1..5, do: build_article_for_ticker(ticker)

      {:ok, articles} =
        News.list_recent_articles(%{limit: 2}, authorize?: false)

      assert length(articles) == 2
    end
  end

  describe "ticker relationship" do
    require Ash.Query

    test "preloads the related ticker on read" do
      ticker = build_ticker(%{symbol: "REL"})
      %{id: id} = build_article_for_ticker(ticker)

      {:ok, loaded} = News.get_article(id, load: [:ticker], authorize?: false)

      assert loaded.ticker.id == ticker.id
      assert loaded.ticker.symbol == "REL"
    end

    test "blocks ticker deletion when articles reference it (on_delete: :restrict)" do
      ticker = build_ticker(%{symbol: "PROT"})
      _article = build_article_for_ticker(ticker)

      # The DB-level FK should reject the delete. Ash surfaces this as
      # an Invalid error wrapping the constraint violation.
      assert {:error, _} =
               Tickers.destroy_ticker(ticker, authorize?: false)
    end
  end

  describe "policies" do
    setup do
      ticker = build_ticker(%{symbol: "POLART"})
      article = build_article_for_ticker(ticker)
      {:ok, ticker: ticker, article: article}
    end

    test "system actor can ingest" do
      assert {:ok, _} =
               News.ingest_article(
                 valid_article_attrs(%{symbol: "SYSING"}),
                 actor: LongOrShort.Accounts.SystemActor.new()
               )
    end

    test "admin can ingest" do
      admin = build_admin_user()

      assert {:ok, _} =
               News.ingest_article(
                 valid_article_attrs(%{symbol: "ADMING"}),
                 actor: admin
               )
    end

    test "trader can read", %{article: article} do
      trader = build_trader_user()

      {:ok, fetched} = News.get_article(article.id, actor: trader)
      assert fetched.id == article.id
    end

    test "trader cannot ingest" do
      trader = build_trader_user()

      assert {:error, %Ash.Error.Forbidden{}} =
               News.ingest_article(
                 valid_article_attrs(%{symbol: "TRDING"}),
                 actor: trader
               )
    end

    test "nil actor sees empty list when reading (filtered by policy)" do
      assert {:ok, []} = News.list_recent_articles(actor: nil)
    end

    test "nil actor cannot ingest" do
      assert {:error, %Ash.Error.Forbidden{}} =
               News.ingest_article(
                 valid_article_attrs(%{symbol: "NILING"}),
                 actor: nil
               )
    end
  end
end
