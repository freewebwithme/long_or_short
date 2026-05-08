defmodule LongOrShort.Analysis.NewsAnalysisTest do
  use LongOrShort.DataCase, async: true

  import LongOrShort.{AnalysisFixtures, NewsFixtures, AccountsFixtures}

  alias LongOrShort.{Analysis, News}

  describe "create_news_analysis/2" do
    test "creates a row with valid attrs and sets analyzed_at" do
      article = build_article()
      user = build_trader_user()
      attrs = valid_news_analysis_attrs(%{article_id: article.id, user_id: user.id})

      {:ok, analysis} =
        Analysis.create_news_analysis(attrs, authorize?: false)

      assert analysis.article_id == article.id
      assert analysis.user_id == user.id
      assert analysis.verdict == :trade
      assert analysis.catalyst_strength == :strong
      assert %DateTime{} = analysis.analyzed_at
    end

    test "applies defaults for pump_fade_risk, strategy_match, repetition_count" do
      article = build_article()
      user = build_trader_user()

      attrs =
        valid_news_analysis_attrs(%{article_id: article.id, user_id: user.id})
        |> Map.drop([:pump_fade_risk, :strategy_match, :repetition_count])

      {:ok, analysis} =
        Analysis.create_news_analysis(attrs, authorize?: false)

      assert analysis.pump_fade_risk == :insufficient_data
      assert analysis.strategy_match == :partial
      assert analysis.repetition_count == 1
    end

    test "rejects invalid :verdict" do
      article = build_article()
      user = build_trader_user()

      attrs =
        valid_news_analysis_attrs(%{
          article_id: article.id,
          user_id: user.id,
          verdict: :bogus
        })

      assert {:error, %Ash.Error.Invalid{} = error} =
               Analysis.create_news_analysis(attrs, authorize?: false)

      assert error_on_field?(error, :verdict)
    end

    test "rejects missing required headline_takeaway" do
      article = build_article()
      user = build_trader_user()

      attrs =
        valid_news_analysis_attrs(%{article_id: article.id, user_id: user.id})
        |> Map.delete(:headline_takeaway)

      assert {:error, %Ash.Error.Invalid{} = error} =
               Analysis.create_news_analysis(attrs, authorize?: false)

      assert error_on_field?(error, :headline_takeaway)
    end
  end

  describe "unique_article_user identity" do
    test "second :create with same (article_id, user_id) is rejected" do
      article = build_article()
      user = build_trader_user()
      _first = build_news_analysis(%{article_id: article.id, user_id: user.id})

      attrs = valid_news_analysis_attrs(%{article_id: article.id, user_id: user.id})

      assert {:error, %Ash.Error.Invalid{}} =
               Analysis.create_news_analysis(attrs, authorize?: false)
    end

    test "two distinct users analyzing the same article produce two rows" do
      article = build_article()
      user_a = build_trader_user()
      user_b = build_trader_user()

      first = build_news_analysis(%{article_id: article.id, user_id: user_a.id})
      second = build_news_analysis(%{article_id: article.id, user_id: user_b.id})

      assert first.id != second.id
      assert first.user_id == user_a.id
      assert second.user_id == user_b.id
    end
  end

  describe "upsert_news_analysis/2" do
    test "first call inserts, second call with same (article_id, user_id) updates the same row" do
      article = build_article()
      user = build_trader_user()

      {:ok, first} =
        Analysis.upsert_news_analysis(
          valid_news_analysis_attrs(%{
            article_id: article.id,
            user_id: user.id,
            verdict: :watch
          }),
          authorize?: false
        )

      {:ok, second} =
        Analysis.upsert_news_analysis(
          valid_news_analysis_attrs(%{
            article_id: article.id,
            user_id: user.id,
            verdict: :trade,
            headline_takeaway: "Updated takeaway"
          }),
          authorize?: false
        )

      assert second.id == first.id
      assert second.verdict == :trade
      assert second.headline_takeaway == "Updated takeaway"
    end

    test "advances analyzed_at on re-upsert" do
      article = build_article()
      user = build_trader_user()

      {:ok, first} =
        Analysis.upsert_news_analysis(
          valid_news_analysis_attrs(%{article_id: article.id, user_id: user.id}),
          authorize?: false
        )

      {:ok, second} =
        Analysis.upsert_news_analysis(
          valid_news_analysis_attrs(%{article_id: article.id, user_id: user.id}),
          authorize?: false
        )

      assert DateTime.compare(second.analyzed_at, first.analyzed_at) in [:gt, :eq]
    end
  end

  describe "get_news_analysis_by_article/2" do
    test "returns the analysis for the given article" do
      article = build_article()
      analysis = build_news_analysis(%{article_id: article.id})

      {:ok, found} =
        Analysis.get_news_analysis_by_article(article.id, authorize?: false)

      assert found.id == analysis.id
    end

    test "returns nil when no analysis exists" do
      article = build_article()

      assert {:ok, nil} =
               Analysis.get_news_analysis_by_article(article.id, authorize?: false)
    end
  end

  describe "Article.news_analysis (has_one)" do
    test "loads as the actor's analysis when present" do
      article = build_article()
      user = build_trader_user()
      analysis = build_news_analysis(%{article_id: article.id, user_id: user.id})

      # has_one filters by `^actor(:id)` (LON-109) — must pass actor.
      {:ok, loaded} =
        News.get_article(article.id, load: [:news_analysis], actor: user)

      assert loaded.news_analysis.id == analysis.id
    end

    test "loads as nil when no analysis exists for the actor" do
      article = build_article()
      user = build_trader_user()

      {:ok, loaded} =
        News.get_article(article.id, load: [:news_analysis], actor: user)

      assert is_nil(loaded.news_analysis)
    end

    test "loads as nil when only another user has analyzed the article" do
      article = build_article()
      analyzer = build_trader_user()
      reader = build_trader_user()
      build_news_analysis(%{article_id: article.id, user_id: analyzer.id})

      {:ok, loaded} =
        News.get_article(article.id, load: [:news_analysis], actor: reader)

      assert is_nil(loaded.news_analysis)
    end

    test "blocks article deletion when analysis references it (on_delete: :restrict)" do
      article = build_article()
      _analysis = build_news_analysis(%{article_id: article.id})

      assert {:error, _} = News.destroy_article(article, authorize?: false)
    end
  end

  describe "policies" do
    setup do
      article = build_article()
      owner = build_trader_user()
      analysis = build_news_analysis(%{article_id: article.id, user_id: owner.id})
      {:ok, article: article, analysis: analysis, owner: owner}
    end

    test "system actor can create" do
      other = build_article()
      user = build_trader_user()

      assert {:ok, _} =
               Analysis.create_news_analysis(
                 valid_news_analysis_attrs(%{article_id: other.id, user_id: user.id}),
                 actor: LongOrShort.Accounts.SystemActor.new()
               )
    end

    test "admin can create" do
      admin = build_admin_user()
      other = build_article()
      user = build_trader_user()

      assert {:ok, _} =
               Analysis.create_news_analysis(
                 valid_news_analysis_attrs(%{article_id: other.id, user_id: user.id}),
                 actor: admin
               )
    end

    test "trader can read their own analysis", %{analysis: analysis, owner: owner} do
      {:ok, found} =
        Analysis.get_news_analysis(analysis.id, actor: owner)

      assert found.id == analysis.id
    end

    test "trader cannot read another trader's analysis", %{analysis: analysis} do
      other_trader = build_trader_user()

      # The own-row policy filter excludes rows from other users, so a
      # get_by_id read for another user's analysis surfaces as a wrapped
      # NotFound — the row exists in the DB but is invisible to this
      # actor's query.
      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Analysis.get_news_analysis(analysis.id, actor: other_trader)

      assert Enum.any?(errors, fn err -> err.__struct__ == Ash.Error.Query.NotFound end)
    end

    test "trader cannot create" do
      trader = build_trader_user()
      other = build_article()

      assert {:error, %Ash.Error.Forbidden{}} =
               Analysis.create_news_analysis(
                 valid_news_analysis_attrs(%{article_id: other.id, user_id: trader.id}),
                 actor: trader
               )
    end

    test "nil actor sees nil read", %{article: article} do
      assert {:ok, nil} =
               Analysis.get_news_analysis_by_article(article.id, actor: nil)
    end
  end
end
