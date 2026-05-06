defmodule LongOrShortWeb.AnalyzeLiveTest do
  @moduledoc """
  Tests for the /analyze LiveView.

  Covers:
    - split_paste/1 unit tests (no LiveView mount needed)
    - Form render + validation
    - Form submit → article created → analyzing state
    - PubSub-driven card render on analysis arrival
    - Re-analyze, New analysis, bogus article_id redirect
    - Direct load of /analyze/:id with existing analysis
  """

  use LongOrShortWeb.ConnCase, async: false

  import LongOrShort.AnalysisFixtures
  import Phoenix.LiveViewTest
  import LongOrShort.AccountsFixtures
  import LongOrShort.NewsFixtures
  import LongOrShort.TickersFixtures
  import AshAuthentication.Plug.Helpers, only: [store_in_session: 2]

  alias LongOrShort.AI.MockProvider
  alias LongOrShort.Analysis.Events, as: AnalysisEvents
  alias LongOrShortWeb.AnalyzeLive

  setup do
    MockProvider.reset()
    :ok
  end

  defp log_in_user(conn, user) do
    conn
    |> init_test_session(%{})
    |> store_in_session(user)
  end

  # ── split_paste/1 ─────────────────────────────────────────────────────

  describe "split_paste/1" do
    test "single-line paste returns {title, nil}" do
      assert AnalyzeLive.split_paste("Sky Quarry IPO filing") ==
               {"Sky Quarry IPO filing", nil}
    end

    test "two-line paste returns {first, second}" do
      assert AnalyzeLive.split_paste("Headline here\nBody text here") ==
               {"Headline here", "Body text here"}
    end

    test "many-line paste returns {first, rest joined}" do
      paste = "Headline\nParagraph one.\nParagraph two.\nParagraph three."

      {title, summary} = AnalyzeLive.split_paste(paste)

      assert title == "Headline"
      assert summary == "Paragraph one.\nParagraph two.\nParagraph three."
    end

    test "title longer than 200 chars is truncated" do
      long_title = String.duplicate("A", 250)
      {title, nil} = AnalyzeLive.split_paste(long_title)
      assert String.length(title) == 200
    end

    test "leading and trailing whitespace is stripped" do
      paste = "  Headline  \n  Body text  "
      assert AnalyzeLive.split_paste(paste) == {"Headline", "Body text"}
    end
  end

  # ── Authentication ────────────────────────────────────────────────────

  describe "authentication" do
    test "unauthenticated request redirects to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/analyze")
    end
  end

  # ── Form render ───────────────────────────────────────────────────────

  describe "/analyze form" do
    setup %{conn: conn} do
      user = build_trader_user()
      conn = log_in_user(conn, user)
      {:ok, conn: conn, user: user}
    end

    test "shows form with ticker, source, paste inputs", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/analyze")

      assert html =~ "analyze-form"
      assert html =~ "Ticker"
      assert html =~ "Source"
      assert html =~ "Paste the article"
      assert html =~ "Analyze"
      refute html =~ "Re-analyze"
    end

    test "Analyze nav link is active on /analyze", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/analyze")

      assert html =~ ~s|btn-active|
      assert html =~ "Analyze"
    end

    test "submitting without a ticker shows symbol error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/analyze")

      html =
        view
        |> element("#analyze-form")
        |> render_submit(%{"symbol" => "", "paste" => "Title\nBody"})

      assert html =~ "Ticker is required"
    end

    test "submitting without paste text shows paste error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/analyze")

      html =
        view
        |> element("#analyze-form")
        |> render_submit(%{"symbol" => "BTBD", "paste" => ""})

      assert html =~ "Article text is required"
    end
  end

  # ── Form submit → analyzing state ─────────────────────────────────────

  describe "analyze form submit" do
    setup %{conn: conn} do
      user = build_trader_user()
      build_trading_profile(%{user_id: user.id})
      conn = log_in_user(conn, user)
      build_ticker(%{symbol: "BTBD"})
      {:ok, conn: conn, user: user}
    end

    test "valid submit creates article and enters analyzing state", %{conn: conn} do
      test_pid = self()

      MockProvider.stub(fn _msgs, _tools, _opts ->
        send(test_pid, :ai_called)

        receive do
          :proceed -> {:ok, %{tool_calls: [], text: nil, usage: %{}}}
        after
          5_000 -> {:error, :test_timeout}
        end
      end)

      {:ok, view, _html} = live(conn, ~p"/analyze")

      view
      |> element("#analyze-form")
      |> render_submit(%{
        "symbol" => "BTBD",
        "source" => "benzinga",
        "paste" => "BTBD partnership announced\n\nBTBD Inc. announced a new partnership today."
      })

      assert_receive :ai_called, 2_000

      html = render(view)

      assert html =~ "Re-analyze"
      assert html =~ "Analyzing"
    end
  end

  # ── Analysis arrival via PubSub ───────────────────────────────────────

  describe "analysis card render" do
    setup %{conn: conn} do
      user = build_trader_user()
      conn = log_in_user(conn, user)
      ticker = build_ticker(%{symbol: "SKYQ"})
      article = build_article_for_ticker(ticker, %{title: "Sky Quarry RFP"})
      {:ok, conn: conn, user: user, article: article}
    end

    test "broadcasting analysis_ready renders the card with pills",
         %{conn: conn, article: article} do
      {:ok, view, _html} = live(conn, ~p"/analyze/#{article.id}")

      # Before analysis: analyzing? true because no analysis exists yet
      assert render(view) =~ "Analyzing"

      analysis = build_news_analysis(%{article_id: article.id, verdict: :trade})
      AnalysisEvents.broadcast_analysis_ready(analysis)

      _ = :sys.get_state(view.pid)

      html = render(view)

      assert html =~ "TRADE"
      refute html =~ "Analyzing"
    end

    test "Re-analyze button enters analyzing state again",
         %{conn: conn, article: article, user: user} do
      build_trading_profile(%{user_id: user.id})
      build_news_analysis(%{article_id: article.id, verdict: :skip})

      test_pid = self()

      MockProvider.stub(fn _msgs, _tools, _opts ->
        send(test_pid, :re_analyze_called)

        receive do
          :proceed -> {:ok, %{tool_calls: [], text: nil, usage: %{}}}
        after
          5_000 -> {:error, :test_timeout}
        end
      end)

      {:ok, view, _} = live(conn, ~p"/analyze/#{article.id}")

      view
      |> element("button[phx-click='re_analyze']")
      |> render_click()

      assert_receive :re_analyze_called, 2_000

      html = render(view)
      assert html =~ "Analyzing"
    end

    test "New analysis button navigates to /analyze",
         %{conn: conn, article: article} do
      {:ok, view, _html} = live(conn, ~p"/analyze/#{article.id}")

      view
      |> element("button[phx-click='new_analysis']")
      |> render_click()

      assert_redirect(view, ~p"/analyze")
    end
  end

  # ── Direct load of /analyze/:id ───────────────────────────────────────

  describe "/analyze/:article_id" do
    setup %{conn: conn} do
      user = build_trader_user()
      conn = log_in_user(conn, user)
      {:ok, conn: conn, user: user}
    end

    test "bogus article_id redirects to /analyze with flash", %{conn: conn} do
      bogus_id = Ecto.UUID.generate()

      assert {:error, {:live_redirect, %{to: "/analyze"}}} =
               live(conn, ~p"/analyze/#{bogus_id}")
    end

    test "article with existing analysis renders card (not analyzing)",
         %{conn: conn} do
      ticker = build_ticker(%{symbol: "NVDA"})
      article = build_article_for_ticker(ticker, %{title: "NVDA earnings beat"})
      _analysis = build_news_analysis(%{article_id: article.id, verdict: :trade})

      {:ok, _view, html} = live(conn, ~p"/analyze/#{article.id}")

      assert html =~ "TRADE"
      refute html =~ "Analyzing"
    end

    test "article without analysis shows analyzing spinner", %{conn: conn} do
      ticker = build_ticker(%{symbol: "MSTR"})
      article = build_article_for_ticker(ticker, %{title: "MSTR buys more BTC"})

      {:ok, _view, html} = live(conn, ~p"/analyze/#{article.id}")

      assert html =~ "Analyzing"
    end
  end
end
