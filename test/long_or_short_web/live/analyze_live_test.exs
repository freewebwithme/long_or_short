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
  import LongOrShort.FilingsFixtures
  import LongOrShort.NewsFixtures
  import LongOrShort.TickersFixtures
  import AshAuthentication.Plug.Helpers, only: [store_in_session: 2]

  alias LongOrShort.AI.MockProvider
  alias LongOrShort.Analysis.Events, as: AnalysisEvents
  alias LongOrShort.Filings.Events, as: FilingsEvents
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
      build_trading_profile(%{user_id: user.id})
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
      build_trading_profile(%{user_id: user.id})
      conn = log_in_user(conn, user)
      ticker = build_ticker(%{symbol: "SKYQ"})
      article = build_article_for_ticker(ticker, %{title: "Sky Quarry RFP"})
      {:ok, conn: conn, user: user, article: article}
    end

    test "broadcasting analysis_ready renders the card with pills",
         %{conn: conn, user: user, article: article} do
      {:ok, view, _html} = live(conn, ~p"/analyze/#{article.id}")

      # Before analysis: analyzing? true because no analysis exists yet
      assert render(view) =~ "Analyzing"

      analysis =
        build_news_analysis(%{
          article_id: article.id,
          user_id: user.id,
          verdict: :trade
        })

      AnalysisEvents.broadcast_analysis_ready(analysis)

      _ = :sys.get_state(view.pid)

      html = render(view)

      assert html =~ "TRADE"
      refute html =~ "Analyzing"
    end

    test "Re-analyze button enters analyzing state again",
         %{conn: conn, user: user, article: article} do
      build_news_analysis(%{article_id: article.id, user_id: user.id, verdict: :skip})

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
         %{conn: conn, user: user} do
      ticker = build_ticker(%{symbol: "NVDA"})
      article = build_article_for_ticker(ticker, %{title: "NVDA earnings beat"})

      _analysis =
        build_news_analysis(%{
          article_id: article.id,
          user_id: user.id,
          verdict: :trade
        })

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

  describe "Analyze gate (no TradingProfile)" do
    setup %{conn: conn} do
      user = build_trader_user()
      conn = log_in_user(conn, user)
      {:ok, conn: conn, user: user}
    end

    test ":new mode shows the profile-gate banner and disables submit",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/analyze")

      assert html =~ ~s|id="analyze-profile-gate"|
      assert html =~ "You need a trader profile"
      assert html =~ ~s|href="/profile"|
      assert html =~ ~r/<button[^>]*type="submit"[^>]*disabled/
    end

    test ":new mode server guard rejects programmatic submit",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/analyze")

      html =
        view
        |> element("#analyze-form")
        |> render_submit(%{"symbol" => "BTBD", "paste" => "Title\nBody", "source" => "benzinga"})

      assert html =~ "Set up your trader profile"
    end

    test ":show mode disables Re-analyze button", %{conn: conn} do
      ticker = build_ticker(%{symbol: "RBT"})
      article = build_article_for_ticker(ticker, %{title: "Re-analyze block"})
      build_news_analysis(%{article_id: article.id, verdict: :skip})

      {:ok, _view, html} = live(conn, ~p"/analyze/#{article.id}")

      assert html =~ ~r/<button[^>]*phx-click="re_analyze"[^>]*disabled/
    end

    test ":show mode server guard rejects programmatic re_analyze",
         %{conn: conn} do
      ticker = build_ticker(%{symbol: "RGD"})
      article = build_article_for_ticker(ticker, %{title: "Re-analyze guard"})
      build_news_analysis(%{article_id: article.id, verdict: :skip})

      {:ok, view, _html} = live(conn, ~p"/analyze/#{article.id}")

      html = render_hook(view, "re_analyze", %{})
      assert html =~ "Set up your trader profile"
    end
  end

  # ── Recent analyses section (LON-108) ────────────────────────────────

  describe "Recent analyses section (LON-108)" do
    setup %{conn: conn} do
      user = build_trader_user()
      conn = log_in_user(conn, user)
      {:ok, conn: conn, user: user}
    end

    test "shows empty-state message when no analyses exist", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/analyze")

      assert html =~ "Recent analyses"
      assert html =~ "No analyses yet"
      refute html =~ "Load more"
    end

    test "renders past analyses, newest first", %{conn: conn, user: user} do
      ticker_a = build_ticker(%{symbol: "AAA"})
      ticker_b = build_ticker(%{symbol: "BBB"})
      article_a = build_article_for_ticker(ticker_a, %{title: "AAA headline"})
      article_b = build_article_for_ticker(ticker_b, %{title: "BBB headline"})

      # Sequential creation → BBB has the later id (UUIDv7 timestamp prefix) →
      # BBB appears first under sort: [id: :desc]. Both must be owned by
      # `user` (LON-109) so the per-user policy filter surfaces them.
      build_news_analysis(%{
        article_id: article_a.id,
        user_id: user.id,
        verdict: :trade
      })

      build_news_analysis(%{
        article_id: article_b.id,
        user_id: user.id,
        verdict: :skip
      })

      {:ok, view, _html} = live(conn, ~p"/analyze")
      html = render(view)

      assert html =~ "AAA"
      assert html =~ "BBB"
      assert html =~ "AAA headline"
      assert html =~ "BBB headline"
      refute html =~ "No analyses yet"

      # Sort assertion: BBB (newer) must appear before AAA in the markup.
      bbb_pos = :binary.match(html, "BBB headline") |> elem(0)
      aaa_pos = :binary.match(html, "AAA headline") |> elem(0)
      assert bbb_pos < aaa_pos, "expected BBB (newer) before AAA in rendered list"
    end

    test "row links to /analyze/:article_id", %{conn: conn, user: user} do
      ticker = build_ticker(%{symbol: "ZZZ"})
      article = build_article_for_ticker(ticker)
      build_news_analysis(%{article_id: article.id, user_id: user.id})

      {:ok, _view, html} = live(conn, ~p"/analyze")

      assert html =~ ~s|href="/analyze/#{article.id}"|
    end

    test "ticker filter narrows the list to one ticker", %{conn: conn, user: user} do
      ticker_a = build_ticker(%{symbol: "FILT"})
      ticker_b = build_ticker(%{symbol: "OTHR"})
      article_a = build_article_for_ticker(ticker_a, %{title: "FILT headline"})
      article_b = build_article_for_ticker(ticker_b, %{title: "OTHR headline"})

      build_news_analysis(%{article_id: article_a.id, user_id: user.id})
      build_news_analysis(%{article_id: article_b.id, user_id: user.id})

      {:ok, view, _html} = live(conn, ~p"/analyze")

      html = render_hook(view, "recent_filter_select", %{"symbol" => "FILT"})

      assert html =~ "FILT headline"
      refute html =~ "OTHR headline"
    end

    test "clearing the filter restores the full list", %{conn: conn, user: user} do
      ticker_a = build_ticker(%{symbol: "AAA"})
      ticker_b = build_ticker(%{symbol: "BBB"})
      article_a = build_article_for_ticker(ticker_a, %{title: "AAA headline"})
      article_b = build_article_for_ticker(ticker_b, %{title: "BBB headline"})

      build_news_analysis(%{article_id: article_a.id, user_id: user.id})
      build_news_analysis(%{article_id: article_b.id, user_id: user.id})

      {:ok, view, _html} = live(conn, ~p"/analyze")

      filtered = render_hook(view, "recent_filter_select", %{"symbol" => "AAA"})
      assert filtered =~ "AAA headline"
      refute filtered =~ "BBB headline"

      cleared = render_hook(view, "recent_filter_clear", %{})
      assert cleared =~ "AAA headline"
      assert cleared =~ "BBB headline"
    end

    test "another user's analyses are not visible", %{conn: conn} do
      # Cross-user isolation proof: an analysis owned by a different
      # trader must not leak into this trader's history list.
      other = build_trader_user()
      ticker = build_ticker(%{symbol: "OTH"})
      article = build_article_for_ticker(ticker, %{title: "leaked headline"})
      build_news_analysis(%{article_id: article.id, user_id: other.id})

      {:ok, _view, html} = live(conn, ~p"/analyze")

      refute html =~ "leaked headline"
      assert html =~ "No analyses yet"
    end

    test "load_more appends the next page when more results exist", %{conn: conn, user: user} do
      ticker = build_ticker(%{symbol: "PAGN"})

      # 21 analyses → first page returns 20 with more?: true; load_more
      # delivers the 21st and clears the more? flag. Zero-padded markers
      # ("Take 01" .. "Take 21") on the article title so substring
      # assertions unambiguously match exactly one row — "Take 1" would
      # otherwise match Take 10–19.
      for i <- 1..21 do
        marker = "Take " <> String.pad_leading(Integer.to_string(i), 2, "0")
        article = build_article_for_ticker(ticker, %{title: marker})

        build_news_analysis(%{article_id: article.id, user_id: user.id})
      end

      {:ok, view, html} = live(conn, ~p"/analyze")

      # Take 01 was created first → oldest → on page 2, not page 1.
      refute html =~ "Take 01"
      assert html =~ "Load more"

      html = render_click(view, "load_more_recent")

      assert html =~ "Take 01"
      refute html =~ "Load more"
    end
  end

  describe "dilution profile rendering (LON-162)" do
    setup %{conn: conn} do
      user = build_trader_user()
      build_trading_profile(%{user_id: user.id})
      conn = log_in_user(conn, user)
      {:ok, conn: conn, user: user}
    end

    test "renders live severity from FilingAnalysis on :show",
         %{conn: conn, user: user} do
      ticker = build_ticker(%{symbol: "ANALDIL"})
      article = build_article_for_ticker(ticker, %{title: "Analyze dilution test"})
      build_news_analysis(%{article_id: article.id, user_id: user.id})

      filing = build_filing_for_ticker(ticker, %{filing_type: :s3})
      build_filing_analysis(filing, %{dilution_severity: :critical})

      {:ok, _view, html} = live(conn, ~p"/analyze/#{article.id}")

      assert html =~ "💧"
      assert html =~ "CRITICAL"
    end

    test "subscribes to filings:analyses and re-renders on :new_filing_analysis",
         %{conn: conn, user: user} do
      ticker = build_ticker(%{symbol: "ANALPUB"})
      article = build_article_for_ticker(ticker, %{title: "Analyze pubsub test"})
      build_news_analysis(%{article_id: article.id, user_id: user.id})

      {:ok, view, html} = live(conn, ~p"/analyze/#{article.id}")
      assert html =~ "UNKNOWN"

      filing = build_filing_for_ticker(ticker, %{filing_type: :s1})
      analysis = build_filing_analysis(filing, %{dilution_severity: :high})

      FilingsEvents.broadcast_analysis_ready(analysis)

      _ = :sys.get_state(view.pid)

      html = render(view)
      assert html =~ "HIGH"
      refute html =~ "UNKNOWN"
    end

    test "ignores :new_filing_analysis for a different ticker",
         %{conn: conn, user: user} do
      ticker = build_ticker(%{symbol: "DISPLAY"})
      other_ticker = build_ticker(%{symbol: "OTHER"})

      article = build_article_for_ticker(ticker, %{title: "Displayed article"})
      build_news_analysis(%{article_id: article.id, user_id: user.id})

      {:ok, view, _html} = live(conn, ~p"/analyze/#{article.id}")

      # Broadcast for a ticker that's NOT the displayed article's ticker
      other_filing = build_filing_for_ticker(other_ticker, %{filing_type: :s1})
      other_analysis = build_filing_analysis(other_filing, %{dilution_severity: :critical})

      FilingsEvents.broadcast_analysis_ready(other_analysis)

      _ = :sys.get_state(view.pid)

      html = render(view)
      # Displayed article's pill stays at UNKNOWN — the other ticker's
      # CRITICAL must not leak in.
      assert html =~ "UNKNOWN"
      refute html =~ "CRITICAL"
    end
  end
end
