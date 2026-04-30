defmodule LongOrShortWeb.FeedLiveTest do
  @moduledoc """
  Tests for the /feed LiveView.

  Covers initial render with existing articles, real-time updates via
  Events.broadcast_new_article/1, the empty-state message, and
  authentication redirect.

  Tests broadcast directly via News.Events rather than starting the
  Dummy GenServer — this avoids polling timing issues and makes the
  assertions deterministic.
  """

  use LongOrShortWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import LongOrShort.AccountsFixtures
  import LongOrShort.NewsFixtures
  import AshAuthentication.Plug.Helpers, only: [store_in_session: 2]

  alias LongOrShort.News
  alias LongOrShort.News.Events
  alias LongOrShort.AI.MockProvider
  alias LongOrShort.Analysis
  alias LongOrShort.Analysis.Events, as: AnalysisEvents

  defp log_in_user(conn, user) do
    conn
    |> init_test_session(%{})
    |> store_in_session(user)
  end

  describe "authentication" do
    test "unauthenticated request redirects to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/feed")
    end
  end

  describe "initial render" do
    setup %{conn: conn} do
      user = build_trader_user()
      conn = log_in_user(conn, user)
      {:ok, conn: conn, user: user}
    end

    test "shows empty-state message when no articles exists", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/feed")

      assert html =~ "No articles yet"
      assert html =~ "0 update"
    end

    test "renders existing articles with title, ticker, source", %{conn: conn} do
      ticker = build_ticker(%{symbol: "AAPL"})

      build_article_for_ticker(ticker, %{
        title: "Apple beats Q2 earnings",
        source: :benzinga
      })

      {:ok, _view, html} = live(conn, ~p"/feed")

      assert html =~ "Apple beats Q2 earnings"
      assert html =~ "AAPL"
      assert html =~ "benzinga"
      assert html =~ "1 update"
    end
  end

  describe "real-time updates" do
    setup %{conn: conn} do
      user = build_trader_user()
      conn = log_in_user(conn, user)
      {:ok, conn: conn, user: user}
    end

    test "broadcast appends new article to the stream", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/feed")

      ticker = build_ticker(%{symbol: "TSLA"})

      article =
        build_article_for_ticker(ticker, %{
          title: "Tesla deliveries up 15%",
          source: :benzinga
        })

      # Reload with ticker preloaded — handle_info expects to find the
      # association loadable
      {:ok, article} = News.get_article(article.id, load: [:ticker], authorize?: false)

      Events.broadcast_new_article(article)

      # render() forces the LiveView to process pending messages
      html = render(view)

      assert html =~ "Tesla deliveries up 15%"
      assert html =~ "TSLA"
      assert html =~ "1 update"
    end

    test "multiple broadcasts accumulate in the count", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/feed")

      ticker = build_ticker(%{symbol: "NVDA"})

      for i <- 1..3 do
        article =
          build_article_for_ticker(ticker, %{
            title: "Nvidia headline #{i}",
            source: :benzinga
          })

        {:ok, article} =
          News.get_article(article.id, load: [:ticker], authorize?: false)

        Events.broadcast_new_article(article)
      end

      html = render(view)

      assert html =~ "Nvidia headline 1"
      assert html =~ "Nvidia headline 2"
      assert html =~ "Nvidia headline 3"
      assert html =~ "3 updates"
    end
  end

  describe "analyze workflow" do
    setup %{conn: conn} do
      MockProvider.reset()
      user = build_trader_user()
      conn = log_in_user(conn, user)
      {:ok, conn: conn, user: user}
    end

    defp tool_response(input) do
      {:ok,
       %{
         tool_calls: [%{name: "report_repetition_analysis", input: input}],
         text: nil,
         usage: %{input_tokens: 10, output_tokens: 5}
       }}
    end

    defp valid_input(overrides \\ %{}) do
      Map.merge(
        %{
          "is_repetition" => true,
          "theme" => "partnership",
          "repetition_count" => 4,
          "related_article_ids" => [],
          "fatigue_level" => "high",
          "reasoning" => "fourth partnership headline"
        },
        overrides
      )
    end

    test "shows Analyze button for articles without an analysis", %{conn: conn} do
      ticker = build_ticker(%{symbol: "AAPL"})
      build_article_for_ticker(ticker, %{title: "Apple Q2"})

      {:ok, _view, html} = live(conn, ~p"/feed")

      assert html =~ "Analyze"
      assert html =~ ~s|phx-click="analyze"|
    end

    test "click triggers analysis and renders result inline", %{conn: conn} do
      AnalysisEvents.subscribe()

      ticker = build_ticker(%{symbol: "BTBD"})
      article = build_article_for_ticker(ticker, %{title: "BTBD partnership #4"})

      MockProvider.stub(fn _, _, _ -> tool_response(valid_input()) end)

      {:ok, view, _html} = live(conn, ~p"/feed")

      view
      |> element("button[phx-click='analyze'][phx-value-id='#{article.id}']")
      |> render_click()

      # Once :complete arrives in the test process, the LiveView (which
      # subscribed in mount) has already updated its assigns map.
      assert_receive {:repetition_analysis_started, _}, 1_000
      assert_receive {:repetition_analysis_complete, _}, 2_000

      html = render(view)

      assert html =~ "🔁"
      assert html =~ "4×"
      assert html =~ "partnership"
    end

    test "shows 'analyzing…' while analysis is pending", %{conn: conn} do
      ticker = build_ticker(%{symbol: "PEND"})
      article = build_article_for_ticker(ticker, %{title: "Pending news"})

      {:ok, view, _html} = live(conn, ~p"/feed")

      {:ok, pending} =
        Analysis.start_repetition_analysis(article.id, authorize?: false)

      AnalysisEvents.broadcast_repetition_analysis_started(pending)

      html = render(view)

      assert html =~ "analyzing"
      refute html =~ ~s|phx-click="analyze"|
    end

    test "renders existing :complete analysis on initial mount", %{conn: conn} do
      ticker = build_ticker(%{symbol: "NVDA"})
      article = build_article_for_ticker(ticker, %{title: "NVDA news"})

      {:ok, pending} =
        Analysis.start_repetition_analysis(article.id, authorize?: false)

      {:ok, _completed} =
        Analysis.complete_repetition_analysis(
          pending,
          %{
            is_repetition: true,
            theme: "earnings",
            repetition_count: 2,
            related_article_ids: [],
            fatigue_level: :medium,
            reasoning: "second earnings",
            model_used: "test",
            tokens_used_input: 0,
            tokens_used_output: 0
          },
          authorize?: false
        )

      {:ok, _view, html} = live(conn, ~p"/feed")

      assert html =~ "🔁"
      refute html =~ ~s|phx-click="analyze"|
    end

    test "renders failed analysis with warning icon", %{conn: conn} do
      AnalysisEvents.subscribe()

      ticker = build_ticker(%{symbol: "ERR"})
      article = build_article_for_ticker(ticker, %{title: "Err news"})

      MockProvider.stub(fn _, _, _ -> {:error, {:network_error, :timeout}} end)

      {:ok, view, _html} = live(conn, ~p"/feed")

      view
      |> element("button[phx-click='analyze'][phx-value-id='#{article.id}']")
      |> render_click()

      assert_receive {:repetition_analysis_failed, _}, 2_000

      assert render(view) =~ "⚠"
    end
  end
end
