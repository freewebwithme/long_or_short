defmodule LongOrShort.News.ArticleRawTest do
  @moduledoc """
  Unit tests for `LongOrShort.News.ArticleRaw`.

  The cascade-delete and upsert-on-identity tests are the load-bearing
  ones — they encode the lifecycle contract that `Sources.Pipeline`
  relies on (raw rows belong to articles, and polling can re-emit
  without violating identity).
  """

  use LongOrShort.DataCase, async: true

  import LongOrShort.{NewsFixtures, AccountsFixtures}

  alias LongOrShort.News

  describe "create_article_raw/2" do
    test "creates a raw row attached to an article" do
      article = build_article()

      {:ok, raw} =
        News.create_article_raw(
          %{
            article_id: article.id,
            raw_payload: %{"id" => 42, "headline" => "hello"}
          },
          authorize?: false
        )

      assert raw.article_id == article.id
      assert raw.raw_payload == %{"id" => 42, "headline" => "hello"}
      assert %DateTime{} = raw.fetched_at
    end

    test "requires article_id and raw_payload" do
      article = build_article()

      base = %{
        article_id: article.id,
        raw_payload: %{"x" => 1}
      }

      for {field, _} <- base do
        attrs = Map.delete(base, field)

        assert {:error, %Ash.Error.Invalid{} = error} =
                 News.create_article_raw(attrs, authorize?: false),
               "expected error when missing #{field}"

        assert error_on_field?(error, field)
      end
    end
  end

  describe "upsert on :unique_article identity" do
    test "second create for the same article overwrites raw_payload" do
      article = build_article()

      {:ok, first} =
        News.create_article_raw(
          %{article_id: article.id, raw_payload: %{"v" => 1}},
          authorize?: false
        )

      {:ok, second} =
        News.create_article_raw(
          %{article_id: article.id, raw_payload: %{"v" => 2}},
          authorize?: false
        )

      # Same row (identity collapsed), latest payload wins.
      assert second.id == first.id
      assert second.raw_payload == %{"v" => 2}

      # Still exactly one ArticleRaw for this article.
      assert {:ok, fetched} = News.get_article_raw(article.id, authorize?: false)
      assert fetched.raw_payload == %{"v" => 2}
    end

    test "fetched_at is preserved across upserts (first-capture semantics)" do
      article = build_article()

      {:ok, first} =
        News.create_article_raw(
          %{article_id: article.id, raw_payload: %{"v" => 1}},
          authorize?: false
        )

      # Re-upsert — fetched_at must not advance, otherwise it would
      # silently re-write the "when was this first captured" signal.
      {:ok, second} =
        News.create_article_raw(
          %{article_id: article.id, raw_payload: %{"v" => 2}},
          authorize?: false
        )

      assert DateTime.compare(second.fetched_at, first.fetched_at) == :eq
    end
  end

  describe "cascade delete" do
    test "destroying the parent Article also destroys its ArticleRaw" do
      article = build_article()
      raw = build_article_raw(article)

      assert :ok = News.destroy_article(article, authorize?: false)

      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
               News.get_article_raw(raw.article_id, authorize?: false)
    end
  end

  describe "get_article_raw/2" do
    test "fetches by article_id" do
      article = build_article()
      raw = build_article_raw(article, %{raw_payload: %{"marker" => "found"}})

      assert {:ok, fetched} = News.get_article_raw(article.id, authorize?: false)
      assert fetched.id == raw.id
      assert fetched.raw_payload == %{"marker" => "found"}
    end

    test "returns NotFound for an unknown article_id" do
      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
               News.get_article_raw(Ash.UUID.generate(), authorize?: false)
    end
  end

  describe "Article.article_raw relationship" do
    test "loads the ArticleRaw via the parent Article" do
      article = build_article()
      _raw = build_article_raw(article, %{raw_payload: %{"loaded" => true}})

      loaded = Ash.load!(article, :article_raw, authorize?: false)
      assert loaded.article_raw.raw_payload == %{"loaded" => true}
    end

    test "loads as nil when no ArticleRaw exists" do
      article = build_article()

      loaded = Ash.load!(article, :article_raw, authorize?: false)
      assert is_nil(loaded.article_raw)
    end
  end

  describe "policies" do
    test "system actor can create" do
      article = build_article()

      assert {:ok, _} =
               News.create_article_raw(
                 %{article_id: article.id, raw_payload: %{"x" => 1}},
                 actor: LongOrShort.Accounts.SystemActor.new()
               )
    end

    test "trader can read" do
      article = build_article()
      raw = build_article_raw(article)
      trader = build_trader_user()

      assert {:ok, fetched} = News.get_article_raw(raw.article_id, actor: trader)
      assert fetched.id == raw.id
    end

    test "trader cannot create" do
      article = build_article()
      trader = build_trader_user()

      assert {:error, %Ash.Error.Forbidden{}} =
               News.create_article_raw(
                 %{article_id: article.id, raw_payload: %{"x" => 1}},
                 actor: trader
               )
    end

    test "nil actor cannot create" do
      article = build_article()

      assert {:error, %Ash.Error.Forbidden{}} =
               News.create_article_raw(
                 %{article_id: article.id, raw_payload: %{"x" => 1}},
                 actor: nil
               )
    end
  end
end
