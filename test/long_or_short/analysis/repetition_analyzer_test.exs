defmodule LongOrShort.Analysis.RepetitionAnalyzerTest do
  use LongOrShort.DataCase, async: true

  import LongOrShort.{NewsFixtures, TickersFixtures}

  alias LongOrShort.AI.MockProvider
  alias LongOrShort.Analysis
  alias LongOrShort.Analysis.{Events, RepetitionAnalyzer}

  setup do
    MockProvider.reset()
    :ok
  end

  defp tool_response(input, usage \\ %{input_tokens: 10, output_tokens: 5}) do
    {:ok,
     %{
       tool_calls: [%{name: "report_repetition_analysis", input: input}],
       text: nil,
       usage: usage
     }}
  end

  defp valid_input(overrides \\ %{}) do
    Map.merge(
      %{
        "is_repetition" => true,
        "theme" => "earnings beat",
        "repetition_count" => 2,
        "related_article_ids" => [],
        "fatigue_level" => "medium",
        "reasoning" => "second earnings article this week"
      },
      overrides
    )
  end

  describe "analyze/1 — happy path" do
    test "completes the analysis and broadcasts on PubSub" do
      Events.subscribe()
      article = build_article()

      MockProvider.stub(fn _msgs, _tools, _opts -> tool_response(valid_input()) end)

      assert {:ok, analysis} = RepetitionAnalyzer.analyze(article.id)

      assert analysis.status == :complete
      assert analysis.is_repetition == true
      assert analysis.fatigue_level == :medium
      assert analysis.repetition_count == 2
      assert analysis.tokens_used_input == 10
      assert analysis.tokens_used_output == 5

      # Started broadcast goes out before AI call; complete after.
      assert_receive {:repetition_analysis_started, %{status: :pending, article_id: id}}
                     when id == article.id

      assert_receive {:repetition_analysis_complete, ^analysis}
    end

    test "passes a forced tool_choice to the provider" do
      article = build_article()

      MockProvider.stub(fn _msgs, _tools, opts ->
        assert opts[:tool_choice] == %{type: "tool", name: "report_repetition_analysis"}
        tool_response(valid_input())
      end)

      assert {:ok, _} = RepetitionAnalyzer.analyze(article.id)
    end

    test "two calls produce two separate analysis rows" do
      article = build_article()

      MockProvider.stub(fn _msgs, _tools, _opts -> tool_response(valid_input()) end)

      assert {:ok, a1} = RepetitionAnalyzer.analyze(article.id)
      assert {:ok, a2} = RepetitionAnalyzer.analyze(article.id)

      refute a1.id == a2.id

      {:ok, all} =
        Analysis.list_repetition_analyses_for_article(article.id, authorize?: false)

      assert length(all) == 2
    end
  end

  describe "analyze/1 — past articles" do
    test "excludes the article itself and any older than 30 days" do
      ticker = build_ticker(%{symbol: "PASTX"})
      now = DateTime.utc_now()

      target = build_article_for_ticker(ticker, %{published_at: now})
      recent = build_article_for_ticker(ticker, %{published_at: DateTime.add(now, -1, :day)})

      _too_old =
        build_article_for_ticker(ticker, %{
          published_at: DateTime.add(now, -45, :day),
          title: "ANCIENT NEWS"
        })

      MockProvider.stub(fn messages, _tools, _opts ->
        [%{content: prompt}] = messages

        [_header, past_section] =
          String.split(prompt, "PAST ARTICLES (last 30 days, same ticker)", parts: 2)

        # exclude_id worked: target's own id is not listed under PAST ARTICLES
        refute past_section =~ target.id

        # 30-day filter worked
        refute past_section =~ "ANCIENT NEWS"

        # sanity: the recent (-1 day) article IS listed
        assert past_section =~ recent.id

        tool_response(valid_input())
      end)

      assert {:ok, _} = RepetitionAnalyzer.analyze(target.id)
    end

    test "handles a first-ever article (no past articles)" do
      article = build_article()

      MockProvider.stub(fn messages, _tools, _opts ->
        [%{content: prompt}] = messages
        assert prompt =~ "(no past articles in last 30 days)"
        tool_response(valid_input(%{"is_repetition" => false, "repetition_count" => 1}))
      end)

      assert {:ok, analysis} = RepetitionAnalyzer.analyze(article.id)
      assert analysis.is_repetition == false
      assert analysis.repetition_count == 1
    end
  end

  describe "analyze/1 — failure modes" do
    test "no tool call → :failed with invalid_response" do
      article = build_article()

      MockProvider.stub(fn _, _, _ ->
        {:ok, %{tool_calls: [], text: "I won't comply", usage: %{}}}
      end)

      assert {:ok, analysis} = RepetitionAnalyzer.analyze(article.id)
      assert analysis.status == :failed
      assert analysis.error_message =~ "invalid_response"
    end

    test "missing required field → :failed with validation_failed" do
      article = build_article()

      MockProvider.stub(fn _, _, _ ->
        tool_response(Map.delete(valid_input(), "fatigue_level"))
      end)

      assert {:ok, analysis} = RepetitionAnalyzer.analyze(article.id)
      assert analysis.status == :failed
      assert analysis.error_message =~ "validation_failed"
      assert analysis.error_message =~ "fatigue_level"
    end

    test "invalid fatigue_level value → :failed with validation_failed" do
      article = build_article()

      MockProvider.stub(fn _, _, _ ->
        tool_response(valid_input(%{"fatigue_level" => "extreme"}))
      end)

      assert {:ok, analysis} = RepetitionAnalyzer.analyze(article.id)
      assert analysis.status == :failed
      assert analysis.error_message =~ "validation_failed"
    end

    test "repetition_count < 1 → :failed with validation_failed" do
      article = build_article()

      MockProvider.stub(fn _, _, _ ->
        tool_response(valid_input(%{"repetition_count" => 0}))
      end)

      assert {:ok, analysis} = RepetitionAnalyzer.analyze(article.id)
      assert analysis.status == :failed
      assert analysis.error_message =~ "validation_failed"
    end

    test "non-uuid in related_article_ids → :failed with validation_failed" do
      article = build_article()

      MockProvider.stub(fn _, _, _ ->
        tool_response(valid_input(%{"related_article_ids" => ["not-a-uuid"]}))
      end)

      assert {:ok, analysis} = RepetitionAnalyzer.analyze(article.id)
      assert analysis.status == :failed
      assert analysis.error_message =~ "validation_failed"
    end

    test "rate-limited provider error → :failed with rate_limited tag" do
      article = build_article()

      MockProvider.stub(fn _, _, _ -> {:error, {:rate_limited, "30"}} end)

      assert {:ok, analysis} = RepetitionAnalyzer.analyze(article.id)
      assert analysis.status == :failed
      assert analysis.error_message =~ "rate_limited"
    end

    test "network error → :failed with network_error tag" do
      article = build_article()

      MockProvider.stub(fn _, _, _ -> {:error, {:network_error, :econnrefused}} end)

      assert {:ok, analysis} = RepetitionAnalyzer.analyze(article.id)
      assert analysis.status == :failed
      assert analysis.error_message =~ "network_error"
    end

    test "http_error → :failed with http_error tag" do
      article = build_article()

      MockProvider.stub(fn _, _, _ -> {:error, {:http_error, 500, "boom"}} end)

      assert {:ok, analysis} = RepetitionAnalyzer.analyze(article.id)
      assert analysis.status == :failed
      assert analysis.error_message =~ "http_error"
    end

    test "broadcasts a :failed event on failure" do
      Events.subscribe()
      article = build_article()

      MockProvider.stub(fn _, _, _ -> {:error, {:network_error, :timeout}} end)

      assert {:ok, %{status: :failed} = analysis} =
               RepetitionAnalyzer.analyze(article.id)

      assert_receive {:repetition_analysis_failed, ^analysis}
      refute_receive {:repetition_analysis_complete, _}, 50
    end
  end

  describe "analyze/1 — preconditions" do
    test "non-existent article id returns an error before creating a pending row" do
      missing_id = Ecto.UUID.generate()

      assert {:error, _} = RepetitionAnalyzer.analyze(missing_id)

      {:ok, all} =
        Analysis.list_repetition_analyses_for_article(missing_id, authorize?: false)

      assert all == []
    end
  end

  describe "analyze/1 — race guard" do
    test "returns {:error, :already_in_progress} when a :pending analysis exists" do
      article = build_article()

      {:ok, _pending} =
        Analysis.start_repetition_analysis(article.id, authorize?: false)

      assert {:error, :already_in_progress} =
               RepetitionAnalyzer.analyze(article.id)

      # Only the original :pending row should exist; no duplicate created.
      {:ok, all} =
        Analysis.list_repetition_analyses_for_article(article.id, authorize?: false)

      assert length(all) == 1
    end

    test "lets a new analysis through after the previous one completes" do
      article = build_article()

      MockProvider.stub(fn _, _, _ -> tool_response(valid_input()) end)

      assert {:ok, %{status: :complete}} = RepetitionAnalyzer.analyze(article.id)

      # Second call should succeed because no :pending exists.
      assert {:ok, %{status: :complete}} = RepetitionAnalyzer.analyze(article.id)
    end
  end
end
