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

  import LongOrShort.AnalysisFixtures
  import Phoenix.LiveViewTest
  import LongOrShort.AccountsFixtures
  import LongOrShort.NewsFixtures
  import LongOrShort.TickersFixtures
  import AshAuthentication.Plug.Helpers, only: [store_in_session: 2]

  alias LongOrShort.News
  alias LongOrShort.News.Events
  alias LongOrShort.AI.MockProvider
  alias LongOrShort.Analysis.Events, as: AnalysisEvents

  setup do
    MockProvider.reset()
    :ok
  end

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

  describe "live price label" do
    setup %{conn: conn} do
      user = build_trader_user()
      conn = log_in_user(conn, user)
      {:ok, conn: conn, user: user}
    end

    test "renders initial price as data-initial-price for a ticker with last_price",
         %{conn: conn} do
      ticker = build_ticker(%{symbol: "AAPL", last_price: Decimal.new("215.42")})
      build_article_for_ticker(ticker, %{title: "Apple news"})

      {:ok, _view, html} = live(conn, ~p"/feed")

      assert html =~ ~s|data-symbol="AAPL"|
      assert html =~ ~s|data-initial-price="215.42"|
    end

    test "leaves data-initial-price empty when last_price is nil", %{conn: conn} do
      ticker = build_ticker(%{symbol: "NOPRICE"})
      build_article_for_ticker(ticker, %{title: "No-price news"})

      {:ok, _view, html} = live(conn, ~p"/feed")

      assert html =~ ~s|data-symbol="NOPRICE"|
      assert html =~ ~s|data-initial-price=""|
    end

    test "pushes price_tick event to the client on PubSub broadcast", %{conn: conn} do
      ticker = build_ticker(%{symbol: "TSLA", last_price: Decimal.new("100.00")})
      build_article_for_ticker(ticker, %{title: "Tesla news"})

      {:ok, view, _html} = live(conn, ~p"/feed")

      Phoenix.PubSub.broadcast(
        LongOrShort.PubSub,
        "prices",
        {:price_tick, "TSLA", Decimal.new("250.42")}
      )

      assert_push_event view, "price_tick", %{symbol: "TSLA", price: "250.42"}
    end

    test "successive ticks each emit a push_event", %{conn: conn} do
      build_ticker(%{symbol: "AAPL"})
      {:ok, view, _html} = live(conn, ~p"/feed")

      Phoenix.PubSub.broadcast(
        LongOrShort.PubSub,
        "prices",
        {:price_tick, "AAPL", Decimal.new("100.00")}
      )

      Phoenix.PubSub.broadcast(
        LongOrShort.PubSub,
        "prices",
        {:price_tick, "AAPL", Decimal.new("101.50")}
      )

      assert_push_event view, "price_tick", %{symbol: "AAPL", price: "100.00"}
      assert_push_event view, "price_tick", %{symbol: "AAPL", price: "101.50"}
    end

    test "nav highlights Feed as active", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/feed")

      assert html =~ ~r|href="/feed"[^>]*btn-active|
      refute html =~ ~r|href="/"[^>]*btn-active[^>]*>\s*Dashboard|
    end
  end

  describe "analysis card rendering" do
    setup %{conn: conn} do
      user = build_trader_user()
      build_trading_profile(%{user_id: user.id})
      conn = log_in_user(conn, user)
      {:ok, conn: conn, user: user}
    end

    test "pre-analyzed article shows all 6 pills + headline_takeaway",
         %{conn: conn, user: user} do
      ticker = build_ticker(%{symbol: "AAPL"})

      article =
        build_article_for_ticker(ticker, %{title: "Apple Q2 partnership"})

      # default fixture: verdict :trade, catalyst_strength :strong,
      # sentiment :positive, llm_provider :claude
      # plus resource defaults: pump_fade_risk :insufficient_data,
      # strategy_match :partial, repetition_count 1
      build_news_analysis(%{article_id: article.id, user_id: user.id})

      {:ok, _view, html} = live(conn, ~p"/feed")

      # 6 pill values (uppercase, underscores → spaces)
      assert html =~ "STRONG"
      assert html =~ "PARTNERSHIP"
      assert html =~ "POSITIVE"
      assert html =~ "INSUFFICIENT DATA"
      assert html =~ "PARTIAL"
      assert html =~ "TRADE"

      # headline + Detail toggle
      assert html =~ "Catalyst-driven move"
      assert html =~ "Detail view"

      # Analyze button hidden when analysis present
      refute html =~ ~s|phx-click="analyze"|
    end

    test "un-analyzed article shows Analyze button, no pills",
         %{conn: conn} do
      ticker = build_ticker(%{symbol: "TSLA"})
      build_article_for_ticker(ticker, %{title: "Tesla deliveries"})

      {:ok, _view, html} = live(conn, ~p"/feed")

      assert html =~ ~s|phx-click="analyze"|
      refute html =~ "Strategy:"
      refute html =~ "Pump-fade:"
    end

    test "click Analyze enters analyzing state with skeleton + spinner",
         %{conn: conn} do
      test_pid = self()

      # Stub blocks until released — keeps Task pending so we can
      # observe the analyzing state deterministically
      MockProvider.stub(fn _msgs, _tools, _opts ->
        send(test_pid, :ai_called)

        receive do
          :proceed -> {:ok, %{tool_calls: [], text: nil, usage: %{}}}
        after
          5_000 -> {:error, :test_timeout}
        end
      end)

      ticker = build_ticker(%{symbol: "BTBD", last_price: Decimal.new("1.82")})
      article = build_article_for_ticker(ticker, %{title: "BTBD partnership"})

      {:ok, view, _html} = live(conn, ~p"/feed")

      view
      |> element("button[phx-click='analyze'][phx-value-id='#{article.id}']")
      |> render_click()

      # Wait until the Task actually called AI — proves analyze handler ran
      # and the Task is in flight
      assert_receive :ai_called, 1_000

      html = render(view)

      assert html =~ "Analyzing"
      assert html =~ "loading-spinner"
      assert html =~ "animate-pulse"
      refute html =~ ~s|phx-click="analyze"|
    end

    test "broadcasting :news_analysis_ready replaces button with pills",
         %{conn: conn, user: user} do
      ticker = build_ticker(%{symbol: "SKYQ"})
      article = build_article_for_ticker(ticker, %{title: "Sky Quarry RFP"})

      {:ok, view, _html} = live(conn, ~p"/feed")

      # Pre-condition: Analyze button visible
      assert render(view) =~ ~s|phx-click="analyze"|

      # Build the analysis row (skips the actual analyzer) and broadcast
      # exactly what the analyzer would send
      analysis =
        build_news_analysis(%{article_id: article.id, user_id: user.id, verdict: :skip})

      AnalysisEvents.broadcast_analysis_ready(analysis)

      # Sync: wait for LiveView to drain handle_info
      _ = :sys.get_state(view.pid)

      html = render(view)

      assert html =~ "SKIP"
      refute html =~ ~s|phx-click="analyze"|
    end

    test "click Detail toggle expands the 5 markdown sections",
         %{conn: conn, user: user} do
      ticker = build_ticker(%{symbol: "BTBD"})
      article = build_article_for_ticker(ticker, %{title: "BTBD news"})

      build_news_analysis(%{
        article_id: article.id,
        user_id: user.id,
        detail_summary: "Test summary body.",
        detail_positives: "- Strong partner\n- Solid balance sheet",
        detail_concerns: "- Float dilution risk",
        detail_checklist: "- RVOL > 2x\n- Hold above $1.50",
        detail_recommendation: "Watch for confirmation."
      })

      {:ok, view, _html} = live(conn, ~p"/feed")

      # Pre-condition: detail section not rendered
      refute render(view) =~ "Pre-entry checklist"

      view
      |> element("button[phx-click='toggle_detail'][phx-value-id='#{article.id}']")
      |> render_click()

      html = render(view)

      assert html =~ "Summary"
      assert html =~ "Positives"
      assert html =~ "Concerns"
      assert html =~ "Pre-entry checklist"
      assert html =~ "Recommendation"

      # MDEx renders bullet list as <ul><li>…</li></ul>
      assert html =~ "<li>Strong partner</li>"
    end

    test "Phase 1 stub fields render with dashed border + tooltip",
         %{conn: conn, user: user} do
      ticker = build_ticker(%{symbol: "TEST"})
      article = build_article_for_ticker(ticker, %{title: "Test article"})

      # Fixture omits :pump_fade_risk and :strategy_match → resource
      # defaults (:insufficient_data and :partial) apply
      build_news_analysis(%{article_id: article.id, user_id: user.id})

      {:ok, _view, html} = live(conn, ~p"/feed")

      assert html =~ "border-dashed"
      assert html =~ "Phase 1 stub"
    end
  end

  describe "Analyze gate (no TradingProfile)" do
    setup %{conn: conn} do
      user = build_trader_user()
      conn = log_in_user(conn, user)
      {:ok, conn: conn, user: user}
    end

    test "renders Analyze as a /profile link with tooltip", %{conn: conn} do
      ticker = build_ticker(%{symbol: "GATE"})
      build_article_for_ticker(ticker, %{title: "Gated article"})

      {:ok, _view, html} = live(conn, ~p"/feed")

      assert html =~ "Set up your trader profile"
      assert html =~ ~s|href="/profile"|
      refute html =~ ~s|phx-click="analyze"|
    end

    test "server-side guard rejects programmatic analyze events", %{conn: conn} do
      ticker = build_ticker(%{symbol: "GUARD"})
      article = build_article_for_ticker(ticker, %{title: "Guarded article"})

      {:ok, view, _html} = live(conn, ~p"/feed")

      # Bypass the disabled UI by dispatching the event directly
      html = render_hook(view, "analyze", %{"id" => article.id})

      assert html =~ "Set up your trader profile"
    end
  end

  describe "ticker filter" do
    setup %{conn: conn} do
      user = build_trader_user()
      build_trading_profile(%{user_id: user.id})
      conn = log_in_user(conn, user)
      {:ok, conn: conn, user: user}
    end

    test "selecting a ticker narrows the feed to that ticker's articles", %{conn: conn} do
      apple = build_ticker(%{symbol: "AAPL", company_name: "Apple Inc"})
      tesla = build_ticker(%{symbol: "TSLA"})

      build_article_for_ticker(apple, %{title: "Apple in the news"})
      build_article_for_ticker(tesla, %{title: "Tesla unrelated"})

      {:ok, view, _html} = live(conn, ~p"/feed")

      view
      |> form("#feed-ticker-filter form", %{query: "AAPL"})
      |> render_change()

      html =
        view
        |> element("button[phx-click='ticker_filter_select'][phx-value-symbol='AAPL']")
        |> render_click()

      assert html =~ "Apple in the news"
      refute html =~ "Tesla unrelated"
    end

    test "clearing the ticker filter restores the unfiltered feed", %{conn: conn} do
      apple = build_ticker(%{symbol: "AAPL"})
      tesla = build_ticker(%{symbol: "TSLA"})

      build_article_for_ticker(apple, %{title: "Apple article"})
      build_article_for_ticker(tesla, %{title: "Tesla article"})

      {:ok, view, _html} = live(conn, ~p"/feed")

      view
      |> form("#feed-ticker-filter form", %{query: "AAPL"})
      |> render_change()

      view
      |> element("button[phx-click='ticker_filter_select'][phx-value-symbol='AAPL']")
      |> render_click()

      html = render_click(view, "ticker_filter_clear")

      assert html =~ "Apple article"
      assert html =~ "Tesla article"
    end
  end

  describe "keyset pagination" do
    setup %{conn: conn} do
      user = build_trader_user()
      build_trading_profile(%{user_id: user.id})
      conn = log_in_user(conn, user)
      {:ok, conn: conn, user: user}
    end

    test "Load more button appears only when there are more pages", %{conn: conn} do
      ticker = build_ticker(%{symbol: "PG"})

      # Single article — well under @page_limit, no Load more button
      build_article_for_ticker(ticker, %{title: "Only one"})

      {:ok, _view, html} = live(conn, ~p"/feed")
      refute html =~ ~s|phx-click="load_more"|
    end

    test "Load more appends the next page without losing the first", %{conn: conn} do
      ticker = build_ticker(%{symbol: "PG"})

      # 35 articles — first page = 30, second page = 5, more? true on first
      first_titles = for i <- 1..35, do: "Article #{String.pad_leading(to_string(i), 2, "0")}"

      Enum.each(first_titles, fn title ->
        build_article_for_ticker(ticker, %{title: title})
      end)

      {:ok, view, html} = live(conn, ~p"/feed")
      assert html =~ ~s|phx-click="load_more"|

      # The 5 oldest titles aren't on page 1
      refute html =~ "Article 01"
      refute html =~ "Article 05"

      html = render_click(view, "load_more")

      # After loading: oldest visible, newest still visible
      assert html =~ "Article 01"
      assert html =~ "Article 35"

      # No more pages — button gone
      refute html =~ ~s|phx-click="load_more"|
    end

    test "live :new_article broadcast still prepends after Load more", %{conn: conn} do
      ticker = build_ticker(%{symbol: "PG"})
      for i <- 1..35, do: build_article_for_ticker(ticker, %{title: "Article #{i}"})

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_click(view, "load_more")

      # Now broadcast a brand-new article
      new_ticker = build_ticker(%{symbol: "FRESH"})
      new_article = build_article_for_ticker(new_ticker, %{title: "Hot off the press"})
      {:ok, new_article} = News.get_article(new_article.id, load: [:ticker], authorize?: false)
      News.Events.broadcast_new_article(new_article)

      html = render(view)
      assert html =~ "Hot off the press"
      # Pagination state preserved — earlier items still there
      assert html =~ "Article 1"
    end
  end
end
