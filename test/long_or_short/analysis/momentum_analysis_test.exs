defmodule LongOrShort.Analysis.MomentumAnalysisTest do
  use LongOrShort.DataCase, async: true

  import LongOrShort.{AnalysisFixtures, NewsFixtures, AccountsFixtures}

  alias LongOrShort.{Analysis, News}

  describe "create_momentum_analysis/2" do
    test "creates a row with valid attrs and sets analyzed_at" do
      article = build_article()
      attrs = valid_momentum_analysis_attrs(%{article_id: article.id})

      {:ok, analysis} =
        Analysis.create_momentum_analysis(attrs, authorize?: false)

      assert analysis.article_id == article.id
      assert analysis.verdict == :trade
      assert analysis.catalyst_strength == :strong
      assert %DateTime{} = analysis.analyzed_at
    end

    test "applies defaults for pump_fade_risk, strategy_match, repetition_count" do
      article = build_article()

      attrs =
        valid_momentum_analysis_attrs(%{article_id: article.id})
        |> Map.drop([:pump_fade_risk, :strategy_match, :repetition_count])

      {:ok, analysis} =
        Analysis.create_momentum_analysis(attrs, authorize?: false)

      assert analysis.pump_fade_risk == :insufficient_data
      assert analysis.strategy_match == :partial
      assert analysis.repetition_count == 1
    end

    test "rejects invalid :verdict" do
      article = build_article()
      attrs = valid_momentum_analysis_attrs(%{article_id: article.id, verdict: :bogus})

      assert {:error, %Ash.Error.Invalid{} = error} =
               Analysis.create_momentum_analysis(attrs, authorize?: false)

      assert error_on_field?(error, :verdict)
    end

    test "rejects missing required headline_takeaway" do
      article = build_article()

      attrs =
        valid_momentum_analysis_attrs(%{article_id: article.id})
        |> Map.delete(:headline_takeaway)

      assert {:error, %Ash.Error.Invalid{} = error} =
               Analysis.create_momentum_analysis(attrs, authorize?: false)

      assert error_on_field?(error, :headline_takeaway)
    end
  end

  describe "unique_article identity" do
    test "second :create with same article_id is rejected" do
      article = build_article()
      _first = build_momentum_analysis(%{article_id: article.id})

      attrs = valid_momentum_analysis_attrs(%{article_id: article.id})

      assert {:error, %Ash.Error.Invalid{}} =
               Analysis.create_momentum_analysis(attrs, authorize?: false)
    end
  end

  describe "upsert_momentum_analysis/2" do
    test "first call inserts, second call with same article_id updates the same row" do
      article = build_article()

      {:ok, first} =
        Analysis.upsert_momentum_analysis(
          valid_momentum_analysis_attrs(%{article_id: article.id, verdict: :watch}),
          authorize?: false
        )

      {:ok, second} =
        Analysis.upsert_momentum_analysis(
          valid_momentum_analysis_attrs(%{
            article_id: article.id,
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

      {:ok, first} =
        Analysis.upsert_momentum_analysis(
          valid_momentum_analysis_attrs(%{article_id: article.id}),
          authorize?: false
        )

      {:ok, second} =
        Analysis.upsert_momentum_analysis(
          valid_momentum_analysis_attrs(%{article_id: article.id}),
          authorize?: false
        )

      assert DateTime.compare(second.analyzed_at, first.analyzed_at) in [:gt, :eq]
    end
  end

  describe "get_momentum_analysis_by_article/2" do
    test "returns the analysis for the given article" do
      article = build_article()
      analysis = build_momentum_analysis(%{article_id: article.id})

      {:ok, found} =
        Analysis.get_momentum_analysis_by_article(article.id, authorize?: false)

      assert found.id == analysis.id
    end

    test "returns nil when no analysis exists" do
      article = build_article()

      assert {:ok, nil} =
               Analysis.get_momentum_analysis_by_article(article.id, authorize?: false)
    end
  end

  describe "Article.momentum_analysis (has_one)" do
    test "loads when present" do
      article = build_article()
      analysis = build_momentum_analysis(%{article_id: article.id})

      {:ok, loaded} =
        News.get_article(article.id, load: [:momentum_analysis], authorize?: false)

      assert loaded.momentum_analysis.id == analysis.id
    end

    test "loads as nil when absent" do
      article = build_article()

      {:ok, loaded} =
        News.get_article(article.id, load: [:momentum_analysis], authorize?: false)

      assert is_nil(loaded.momentum_analysis)
    end

    test "blocks article deletion when analysis references it (on_delete: :restrict)" do
      article = build_article()
      _analysis = build_momentum_analysis(%{article_id: article.id})

      assert {:error, _} = News.destroy_article(article, authorize?: false)
    end
  end

  describe "policies" do
    setup do
      article = build_article()
      analysis = build_momentum_analysis(%{article_id: article.id})
      {:ok, article: article, analysis: analysis}
    end

    test "system actor can create" do
      other = build_article()

      assert {:ok, _} =
               Analysis.create_momentum_analysis(
                 valid_momentum_analysis_attrs(%{article_id: other.id}),
                 actor: LongOrShort.Accounts.SystemActor.new()
               )
    end

    test "admin can create" do
      admin = build_admin_user()
      other = build_article()

      assert {:ok, _} =
               Analysis.create_momentum_analysis(
                 valid_momentum_analysis_attrs(%{article_id: other.id}),
                 actor: admin
               )
    end

    test "trader can read", %{analysis: analysis} do
      trader = build_trader_user()

      {:ok, found} =
        Analysis.get_momentum_analysis(analysis.id, actor: trader)

      assert found.id == analysis.id
    end

    test "trader cannot create" do
      trader = build_trader_user()
      other = build_article()

      assert {:error, %Ash.Error.Forbidden{}} =
               Analysis.create_momentum_analysis(
                 valid_momentum_analysis_attrs(%{article_id: other.id}),
                 actor: trader
               )
    end

    test "nil actor sees nil read", %{article: article} do
      assert {:ok, nil} =
               Analysis.get_momentum_analysis_by_article(article.id, actor: nil)
    end
  end
end
