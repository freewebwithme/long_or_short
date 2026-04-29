defmodule LongOrShort.Analysis.RepetitionAnalysisTest do
  use LongOrShort.DataCase, async: true

  import LongOrShort.{AnalysisFixtures, NewsFixtures, AccountsFixtures}

  alias LongOrShort.Analysis
  alias LongOrShort.Analysis.RepetitionAnalysis

  describe "start_repetition_analysis/2" do
    test "creates a :pending row for the given article" do
      article = build_article()

      {:ok, analysis} =
        Analysis.start_repetition_analysis(article.id, authorize?: false)

      assert analysis.article_id == article.id
      assert analysis.status == :pending
      assert is_nil(analysis.is_repetition)
      assert is_nil(analysis.fatigue_level)
    end

    test "requires an article_id" do
      assert {:error, %Ash.Error.Invalid{} = error} =
               Analysis.start_repetition_analysis(nil, authorize?: false)

      assert error_on_field?(error, :article_id)
    end
  end

  describe "complete_repetition_analysis/3" do
    test "fills in result fields and flips status to :complete" do
      article = build_article()
      {:ok, pending} = Analysis.start_repetition_analysis(article.id, authorize?: false)

      {:ok, completed} =
        Analysis.complete_repetition_analysis(
          pending,
          %{
            is_repetition: true,
            theme: "earnings",
            repetition_count: 3,
            related_article_ids: [],
            fatigue_level: :high,
            reasoning: "third earnings-beat headline today",
            model_used: "claude-opus-4-7",
            tokens_used_input: 100,
            tokens_used_output: 50
          },
          authorize?: false
        )

      assert completed.status == :complete
      assert completed.is_repetition == true
      assert completed.fatigue_level == :high
      assert completed.repetition_count == 3
      assert completed.tokens_used_input == 100
    end

    test "rejects invalid fatigue_level" do
      article = build_article()
      {:ok, pending} = Analysis.start_repetition_analysis(article.id, authorize?: false)

      assert {:error, %Ash.Error.Invalid{} = error} =
               Analysis.complete_repetition_analysis(
                 pending,
                 %{
                   is_repetition: false,
                   fatigue_level: :invalid,
                   reasoning: "x"
                 },
                 authorize?: false
               )

      assert error_on_field?(error, :fatigue_level)
    end

    test "requires is_repetition, fatigue_level, reasoning" do
      article = build_article()
      {:ok, pending} = Analysis.start_repetition_analysis(article.id, authorize?: false)

      assert {:error, %Ash.Error.Invalid{}} =
               Analysis.complete_repetition_analysis(pending, %{}, authorize?: false)
    end
  end

  describe "fail_repetition_analysis/3" do
    test "records the error and flips status to :failed" do
      article = build_article()
      {:ok, pending} = Analysis.start_repetition_analysis(article.id, authorize?: false)

      {:ok, failed} =
        Analysis.fail_repetition_analysis(
          pending,
          %{error_message: "Claude API timeout"},
          authorize?: false
        )

      assert failed.status == :failed
      assert failed.error_message == "Claude API timeout"
    end

    test "requires an error_message" do
      article = build_article()
      {:ok, pending} = Analysis.start_repetition_analysis(article.id, authorize?: false)

      assert {:error, %Ash.Error.Invalid{} = error} =
               Analysis.fail_repetition_analysis(pending, %{}, authorize?: false)

      assert error_on_field?(error, :error_message)
    end
  end

  describe "article relationship" do
    test "belongs_to :article loads correctly" do
      article = build_article()
      analysis = build_repetition_analysis(%{article_id: article.id})

      {:ok, [loaded]} =
        Analysis.list_repetition_analyses_for_article(
          article.id,
          load: [:article],
          authorize?: false
        )

      assert loaded.id == analysis.id
      assert loaded.article.id == article.id
    end

    test "blocks article deletion when analyses reference it (on_delete: :restrict)" do
      article = build_article()
      _analysis = build_repetition_analysis(%{article_id: article.id})

      assert {:error, _} =
               LongOrShort.News.destroy_article(article, authorize?: false)
    end
  end

  describe "list_repetition_analyses_for_article/2" do
    test "returns analyses for the article, newest first" do
      article = build_article()
      other = build_article()

      _a1 = build_repetition_analysis(%{article_id: article.id})
      _a2 = build_repetition_analysis(%{article_id: article.id})
      _excluded = build_repetition_analysis(%{article_id: other.id})

      {:ok, results} =
        Analysis.list_repetition_analyses_for_article(article.id, authorize?: false)

      assert length(results) == 2
      assert Enum.all?(results, &(&1.article_id == article.id))

      [first, second] = results
      assert DateTime.compare(first.created_at, second.created_at) in [:gt, :eq]
    end

    test "returns empty list when no analyses" do
      article = build_article()

      {:ok, results} =
        Analysis.list_repetition_analyses_for_article(article.id, authorize?: false)

      assert results == []
    end
  end

  describe "get_latest_repetition_analysis/2" do
    test "returns the most recent analysis" do
      article = build_article()

      _older = build_repetition_analysis(%{article_id: article.id, theme: "first"})
      newer = build_repetition_analysis(%{article_id: article.id, theme: "second"})

      {:ok, latest} =
        Analysis.get_latest_repetition_analysis(article.id, authorize?: false)

      assert latest.id == newer.id
    end

    test "returns nil when no analyses exist" do
      article = build_article()

      assert {:ok, nil} =
               Analysis.get_latest_repetition_analysis(article.id, authorize?: false)
    end
  end

  describe "policies" do
    setup do
      article = build_article()
      {:ok, pending} = Analysis.start_repetition_analysis(article.id, authorize?: false)
      {:ok, article: article, pending: pending}
    end

    test "system actor can start analyses", %{article: article} do
      assert {:ok, _} =
               Analysis.start_repetition_analysis(
                 article.id,
                 actor: LongOrShort.Accounts.SystemActor.new()
               )
    end

    test "admin can start analyses", %{article: article} do
      admin = build_admin_user()

      assert {:ok, _} =
               Analysis.start_repetition_analysis(article.id, actor: admin)
    end

    test "trader can read", %{pending: pending, article: article} do
      trader = build_trader_user()

      {:ok, [loaded]} =
        Analysis.list_repetition_analyses_for_article(article.id, actor: trader)

      assert loaded.id == pending.id
    end

    test "trader cannot start", %{article: article} do
      trader = build_trader_user()

      assert {:error, %Ash.Error.Forbidden{}} =
               Analysis.start_repetition_analysis(article.id, actor: trader)
    end

    test "nil actor sees empty read", %{article: article} do
      assert {:ok, []} =
               Analysis.list_repetition_analyses_for_article(article.id, actor: nil)
    end
  end
end
