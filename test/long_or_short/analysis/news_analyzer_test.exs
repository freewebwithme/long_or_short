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

  # LON-146: when the LLM returns an enum value outside the allowed
  # list, we no longer fail the whole analysis. The field falls back
  # to a per-enum safe default and the row persists so the trader
  # still sees `detail_summary`, `detail_recommendation`, etc.
  describe "analyze/2 — out-of-enum fallbacks (LON-146)" do
    test "invalid catalyst_strength → :unknown fallback, analysis persists", %{
      user: user,
      article: article
    } do
      MockProvider.stub(fn _, _, _ ->
        tool_response(valid_tool_input(%{"catalyst_strength" => "blistering"}))
      end)

      assert {:ok, analysis} = NewsAnalyzer.analyze(article, actor: user)
      assert analysis.catalyst_strength == :unknown
    end

    test "invalid catalyst_type → :other fallback, original preserved in raw_response", %{
      user: user,
      article: article
    } do
      # The exact repro from the ticket: LLM returned "analyst" for a
      # "Top 10 Analyst Forecasts" article, which is not in the allowed
      # catalyst_type list. With the fix, the analysis row persists
      # with catalyst_type=:other and the raw "analyst" string lives on
      # in `raw_response` for audit.
      MockProvider.stub(fn _, _, _ ->
        tool_response(valid_tool_input(%{"catalyst_type" => "analyst"}))
      end)

      assert {:ok, analysis} = NewsAnalyzer.analyze(article, actor: user)
      assert analysis.catalyst_type == :other

      # Audit-preservation: the original out-of-enum value survives in
      # raw_response so a future operator can trace LLM drift.
      [%{"input" => input}] = analysis.raw_response["tool_calls"]
      assert input["catalyst_type"] == "analyst"
    end

    test "invalid sentiment → :neutral fallback, analysis persists", %{
      user: user,
      article: article
    } do
      MockProvider.stub(fn _, _, _ ->
        tool_response(valid_tool_input(%{"sentiment" => "euphoric"}))
      end)

      assert {:ok, analysis} = NewsAnalyzer.analyze(article, actor: user)
      assert analysis.sentiment == :neutral
    end

    test "invalid verdict → :skip fallback (conservative), analysis persists", %{
      user: user,
      article: article
    } do
      # Conservative default: when the model returns a verdict we can't
      # interpret, we don't recommend trading on it.
      MockProvider.stub(fn _, _, _ ->
        tool_response(valid_tool_input(%{"verdict" => "buy"}))
      end)

      assert {:ok, analysis} = NewsAnalyzer.analyze(article, actor: user)
      assert analysis.verdict == :skip
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

  describe "analyze/2 — dilution context (LON-117)" do
    # An `:insufficient` profile mirrors the no-FilingAnalysis-rows
    # default; this is what `Tickers.get_dilution_profile/1` returns
    # for a freshly-created ticker in setup. Spelling it out
    # explicitly keeps each test self-contained.
    defp insufficient_profile do
      %{
        ticker_id: "test-ticker-id",
        overall_severity: :none,
        overall_severity_reason: nil,
        active_atm: nil,
        pending_s1: nil,
        warrant_overhang: nil,
        recent_reverse_split: nil,
        insider_selling_post_filing: false,
        flags: [],
        last_filing_at: nil,
        data_completeness: :insufficient
      }
    end

    defp high_severity_profile do
      %{
        ticker_id: "test-ticker-id",
        overall_severity: :high,
        overall_severity_reason: "ATM > 50% float (12M / 22M shares)",
        active_atm: %{
          remaining_shares: 12_000_000,
          pricing_method: :market_minus_pct,
          pricing_discount_pct: Decimal.new("5.0"),
          registered_at: ~U[2026-02-15 00:00:00.000000Z],
          used_to_date: 8_000_000,
          last_424b_filed_at: ~U[2026-04-30 00:00:00.000000Z],
          source_filing_ids: ["s3-id"]
        },
        pending_s1: nil,
        warrant_overhang: nil,
        recent_reverse_split: nil,
        insider_selling_post_filing: false,
        flags: [:large_overhang],
        last_filing_at: ~U[2026-04-30 00:00:00.000000Z],
        data_completeness: :high
      }
    end

    test "with no FilingAnalysis rows for the ticker, persists :unknown snapshot", %{
      user: user,
      article: article
    } do
      MockProvider.stub(fn _, _, _ -> tool_response() end)

      {:ok, analysis} = NewsAnalyzer.analyze(article, actor: user)

      assert analysis.dilution_severity_at_analysis == :unknown
      assert analysis.dilution_flags_at_analysis == []
      assert analysis.dilution_summary_at_analysis == "Unknown — no dilution data in last 180 days"
    end

    test ":insufficient profile renders 'do NOT assume clean' branch in prompt", %{
      user: user,
      article: article
    } do
      MockProvider.stub(fn _, _, _ -> tool_response() end)

      {:ok, _} =
        NewsAnalyzer.analyze(article, actor: user, dilution_profile: insufficient_profile())

      [{messages, _tools, _opts}] = MockProvider.calls()
      [%{content: sys}, %{content: usr}] = messages

      # The system rules block is the SHORT-bias guidance applied
      # regardless of profile content — make sure it's always
      # injected into the system prompt.
      assert sys =~ "Dilution risk handling"
      assert sys =~ "do NOT implicitly assume the stock is dilution-free"

      # The user-side guard is the per-call data-availability
      # signal — only renders on insufficient data.
      assert usr =~ "## Dilution context"
      assert usr =~ "do NOT assume clean dilution status"
    end

    test "high-severity profile flows into prompt and persists snapshot fields", %{
      user: user,
      article: article
    } do
      MockProvider.stub(fn _, _, _ -> tool_response() end)

      {:ok, analysis} =
        NewsAnalyzer.analyze(article, actor: user, dilution_profile: high_severity_profile())

      # Prompt got the high-severity context.
      [{messages, _tools, _opts}] = MockProvider.calls()
      [_sys, %{content: usr}] = messages
      assert usr =~ "Overall severity: HIGH"
      assert usr =~ "ATM > 50% float (12M / 22M shares)"
      assert usr =~ "Active ATM: 12M shares remaining"
      assert usr =~ "Flags: large_overhang"

      # And the persisted row carries a frozen snapshot of that
      # same context — driving the "show all SHORT verdicts where
      # dilution was critical" query LON-121 will lean on.
      assert analysis.dilution_severity_at_analysis == :high
      assert analysis.dilution_flags_at_analysis == [:large_overhang]
      assert analysis.dilution_summary_at_analysis == "HIGH — ATM > 50% float (12M / 22M shares)"
    end

    test "raw_response includes the dilution_profile under 'dilution_profile' key", %{
      user: user,
      article: article
    } do
      MockProvider.stub(fn _, _, _ -> tool_response() end)

      {:ok, analysis} =
        NewsAnalyzer.analyze(article, actor: user, dilution_profile: high_severity_profile())

      # Jason round-trip means atom keys come back as strings and
      # atom values come back as strings — that's the audit shape.
      assert %{"dilution_profile" => profile_json} = analysis.raw_response
      assert profile_json["overall_severity"] == "high"
      assert profile_json["data_completeness"] == "high"
      assert profile_json["active_atm"]["remaining_shares"] == 12_000_000
    end

    test "re-analysis with a different profile updates the snapshot fields", %{
      user: user,
      article: article
    } do
      MockProvider.stub(fn _, _, _ -> tool_response() end)

      {:ok, first} =
        NewsAnalyzer.analyze(article, actor: user, dilution_profile: insufficient_profile())

      assert first.dilution_severity_at_analysis == :unknown

      {:ok, second} =
        NewsAnalyzer.analyze(article, actor: user, dilution_profile: high_severity_profile())

      assert second.id == first.id
      assert second.dilution_severity_at_analysis == :high
      assert second.dilution_summary_at_analysis == "HIGH — ATM > 50% float (12M / 22M shares)"
    end
  end
end
