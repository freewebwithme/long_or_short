defmodule LongOrShort.Analysis.NewsAnalyzerTest do
  use LongOrShort.DataCase, async: true

  import LongOrShort.{AccountsFixtures, NewsFixtures, TickersFixtures}

  alias LongOrShort.AI.MockProvider
  alias LongOrShort.Analysis.{NewsAnalyzer, NewsAnalysis, Events}
  alias LongOrShort.News

  setup do
    MockProvider.reset()

    user = build_trader_user()
    build_trading_profile(%{user_id: user.id})

    ticker =
      build_ticker(%{
        symbol: "BTBD",
        last_price: Decimal.new("3.45"),
        float_shares: 25_000_000
      })

    raw_article =
      build_article_for_ticker(ticker, %{
        title: "BTBD partners with Aero Velocity",
        summary: "Bit Digital announces aerospace partnership."
      })

    {:ok, article} = News.get_article(raw_article.id, load: [:ticker], authorize?: false)

    {:ok, user: user, ticker: ticker, article: article}
  end

  defp valid_tool_input(overrides \\ %{}) do
    Map.merge(
      %{
        "catalyst_strength" => "strong",
        "catalyst_type" => "partnership",
        "sentiment" => "positive",
        "repetition_count" => 1,
        "verdict" => "trade",
        "headline_takeaway" => "Strong catalyst — take it.",
        "detail_summary" => "Company announced a new aerospace partnership.",
        "detail_positives" => "- Named counterparty (Aero Velocity)\n- Real revenue path",
        "detail_concerns" => "- Small float, expect spike-fade volatility",
        "detail_checklist" => "- Confirm price band\n- Check RVOL",
        "detail_recommendation" => "Trigger long entry on volume confirmation."
      },
      overrides
    )
  end

  defp tool_response(
         input \\ valid_tool_input(),
         usage \\ %{input_tokens: 1234, output_tokens: 567}
       ) do
    {:ok,
     %{
       tool_calls: [%{name: "record_news_analysis", input: input}],
       text: nil,
       usage: usage
     }}
  end

  describe "analyze/2 — happy path" do
    test "returns {:ok, %NewsAnalysis{}} with all LLM-driven fields populated", %{
      user: user,
      article: article
    } do
      MockProvider.stub(fn _, _, _ -> tool_response() end)

      {:ok, %NewsAnalysis{} = analysis} = NewsAnalyzer.analyze(article, actor: user)

      assert analysis.article_id == article.id
      assert analysis.user_id == user.id
      assert analysis.catalyst_strength == :strong
      assert analysis.catalyst_type == :partnership
      assert analysis.sentiment == :positive
      assert analysis.repetition_count == 1
      assert analysis.verdict == :trade
      assert analysis.headline_takeaway =~ "Strong catalyst"
      assert analysis.detail_summary =~ "aerospace partnership"
      assert analysis.detail_positives =~ "Aero Velocity"
      assert analysis.detail_concerns =~ "spike-fade"
      assert analysis.detail_checklist =~ "RVOL"
      assert analysis.detail_recommendation =~ "Trigger long"
      assert %DateTime{} = analysis.analyzed_at
    end

    test "snapshots ticker fields at analysis time", %{
      user: user,
      article: article,
      ticker: ticker
    } do
      MockProvider.stub(fn _, _, _ -> tool_response() end)

      {:ok, analysis} = NewsAnalyzer.analyze(article, actor: user)

      assert Decimal.equal?(analysis.price_at_analysis, ticker.last_price)
      assert analysis.float_shares_at_analysis == ticker.float_shares
      assert is_nil(analysis.rvol_at_analysis)
    end
  end

  describe "analyze/2 — Phase 1 stubs" do
    test "pump_fade_risk, strategy_match, strategy_match_reasons are explicitly set", %{
      user: user,
      article: article
    } do
      MockProvider.stub(fn _, _, _ -> tool_response() end)

      {:ok, analysis} = NewsAnalyzer.analyze(article, actor: user)

      assert analysis.pump_fade_risk == :insufficient_data
      assert analysis.strategy_match == :partial
      assert analysis.strategy_match_reasons == %{}
    end
  end

  describe "analyze/2 — re-analysis (upsert)" do
    test "second analyze on the same article overwrites the existing row", %{
      user: user,
      article: article
    } do
      MockProvider.stub(fn _, _, _ -> tool_response() end)

      {:ok, first} = NewsAnalyzer.analyze(article, actor: user)

      MockProvider.stub(fn _, _, _ ->
        tool_response(
          valid_tool_input(%{"verdict" => "watch", "headline_takeaway" => "Updated take."})
        )
      end)

      {:ok, second} = NewsAnalyzer.analyze(article, actor: user)

      assert second.id == first.id
      assert second.verdict == :watch
      assert second.headline_takeaway == "Updated take."
    end
  end

  describe "analyze/2 — provenance" do
    test "llm_provider, model, and token counts are populated from the response", %{
      user: user,
      article: article
    } do
      MockProvider.stub(fn _, _, _ -> tool_response() end)

      {:ok, analysis} = NewsAnalyzer.analyze(article, actor: user)

      assert analysis.llm_provider == :mock
      assert is_binary(analysis.llm_model)
      assert analysis.input_tokens == 1234
      assert analysis.output_tokens == 567
    end
  end

  describe "analyze/2 — prior articles" do
    test "passes recent same-ticker articles into the prompt builder", %{
      user: user,
      ticker: ticker,
      article: article
    } do
      for i <- 1..3 do
        build_article_for_ticker(ticker, %{
          title: "Prior BTBD news #{i}",
          published_at: DateTime.add(DateTime.utc_now(), -i * 3600, :second)
        })
      end

      MockProvider.stub(fn _, _, _ -> tool_response() end)

      {:ok, _} = NewsAnalyzer.analyze(article, actor: user)

      assert [{messages, _tools, _opts}] = MockProvider.calls()
      [_system, %{content: user_msg}] = messages

      for i <- 1..3 do
        assert user_msg =~ "Prior BTBD news #{i}"
      end
    end

    test "excludes the article being analyzed from prior context", %{user: user, article: article} do
      MockProvider.stub(fn _, _, _ -> tool_response() end)

      {:ok, _} = NewsAnalyzer.analyze(article, actor: user)

      [{messages, _, _}] = MockProvider.calls()
      [_system, %{content: user_msg}] = messages

      # The article's own title appears in "Headline:" but should NOT
      # appear in the PAST ARTICLES block. With only one article in the
      # ticker, the past block renders the placeholder.
      assert user_msg =~ "(no past articles in window)"
    end

    test "respects :prior_window_days — articles older than the window are excluded", %{
      user: user,
      ticker: ticker,
      article: article
    } do
      build_article_for_ticker(ticker, %{
        title: "Ancient news",
        published_at: DateTime.add(DateTime.utc_now(), -30 * 24 * 3600, :second)
      })

      MockProvider.stub(fn _, _, _ -> tool_response() end)

      {:ok, _} = NewsAnalyzer.analyze(article, actor: user, prior_window_days: 14)

      [{messages, _, _}] = MockProvider.calls()
      [_system, %{content: user_msg}] = messages

      refute user_msg =~ "Ancient news"
    end
  end

  describe "analyze/2 — broadcast" do
    test "broadcasts {:news_analysis_ready, %NewsAnalysis{}} on the article-scoped topic", %{
      user: user,
      article: article
    } do
      Events.subscribe_for_article(article.id)
      MockProvider.stub(fn _, _, _ -> tool_response() end)

      {:ok, _} = NewsAnalyzer.analyze(article, actor: user)

      assert_receive {:news_analysis_ready, %NewsAnalysis{} = analysis}, 1_000
      assert analysis.article_id == article.id
    end

    test "does not broadcast on error", %{user: user, article: article} do
      Events.subscribe_for_article(article.id)
      MockProvider.stub(fn _, _, _ -> {:error, :timeout} end)

      assert {:error, _} = NewsAnalyzer.analyze(article, actor: user)

      refute_receive {:news_analysis_ready, _}, 200
    end
  end

  describe "analyze/2 — errors" do
    test "AI provider error → {:error, {:ai_call_failed, reason}}", %{
      user: user,
      article: article
    } do
      MockProvider.stub(fn _, _, _ -> {:error, :timeout} end)

      assert {:error, {:ai_call_failed, :timeout}} =
               NewsAnalyzer.analyze(article, actor: user)
    end

    test "no tool_call in response → {:error, :no_tool_call}", %{user: user, article: article} do
      MockProvider.stub(fn _, _, _ ->
        {:ok, %{tool_calls: [], text: "I cannot do that.", usage: %{}}}
      end)

      assert {:error, :no_tool_call} = NewsAnalyzer.analyze(article, actor: user)
    end

    test "invalid enum value → {:error, {:invalid_enum, field, value}}", %{
      user: user,
      article: article
    } do
      MockProvider.stub(fn _, _, _ ->
        tool_response(valid_tool_input(%{"verdict" => "buy"}))
      end)

      assert {:error, {:invalid_enum, :verdict, "buy"}} =
               NewsAnalyzer.analyze(article, actor: user)
    end

    test "actor without a TradingProfile → {:error, :no_trading_profile}", %{article: article} do
      profile_less_user = build_trader_user()

      MockProvider.stub(fn _, _, _ -> tool_response() end)

      assert {:error, :no_trading_profile} =
               NewsAnalyzer.analyze(article, actor: profile_less_user)
    end

    test "missing :actor opt raises KeyError", %{article: article} do
      assert_raise KeyError, fn ->
        NewsAnalyzer.analyze(article, [])
      end
    end
  end
end
