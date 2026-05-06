defmodule LongOrShortWeb.DashboardLiveTest do
  use LongOrShortWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import LongOrShort.{AccountsFixtures, NewsFixtures, TickersFixtures}
  import AshAuthentication.Plug.Helpers, only: [store_in_session: 2]

  alias LongOrShort.News
  alias LongOrShort.Tickers.WatchlistEvents

  defp log_in_user(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> store_in_session(user)
  end

  describe "authentication" do
    test "unauthenticated request redirects to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/")
    end
  end

  describe "render" do
    setup %{conn: conn} do
      user = build_trader_user()
      conn = log_in_user(conn, user)
      {:ok, conn: conn, user: user}
    end

    test "renders the primary placeholder cards", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ ~s|id="dash-search"|
      assert html =~ ~s|id="dash-indices"|
      assert html =~ ~s|id="dash-news"|
      assert html =~ ~s|id="dash-watchlist"|
      assert html =~ ~s|id="dash-all-news"|
      assert html =~ "Ticker search"
      assert html =~ "Major indices"
      assert html =~ "All news"
      assert html =~ "Watchlist"
    end

    test "nav highlights Dashboard as active", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ ~r|href="/"[^>]*btn-active[^>]*>\s*Dashboard|
      refute html =~ ~r|href="/feed"[^>]*btn-active|
    end
  end

  describe "watchlist widget" do
    setup %{conn: conn} do
      user = build_trader_user()
      conn = log_in_user(conn, user)
      {:ok, conn: conn, user: user}
    end

    test "renders symbols from the user's DB watchlist with PriceLabel hooks", %{
      conn: conn,
      user: user
    } do
      aapl = build_ticker(%{symbol: "AAPL"})
      tsla = build_ticker(%{symbol: "TSLA"})
      build_watchlist_item(%{user_id: user.id, ticker_id: aapl.id})
      build_watchlist_item(%{user_id: user.id, ticker_id: tsla.id})

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "AAPL"
      assert html =~ "TSLA"
      assert html =~ ~s|data-symbol="AAPL"|
      assert html =~ ~s|data-symbol="TSLA"|
    end

    test "shows initial price when ticker has last_price", %{conn: conn, user: user} do
      ticker = build_ticker(%{symbol: "WLTEST", last_price: Decimal.new("42.50")})
      build_watchlist_item(%{user_id: user.id, ticker_id: ticker.id})

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ ~s|data-initial-price="42.50"|
    end

    test "leaves data-initial-price empty when ticker has no last_price", %{
      conn: conn,
      user: user
    } do
      ticker = build_ticker(%{symbol: "NOPRICE"})
      build_watchlist_item(%{user_id: user.id, ticker_id: ticker.id})

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ ~s|data-symbol="NOPRICE"|
      assert html =~ ~s|data-initial-price=""|
    end

    test "pushes price_tick event on PubSub broadcast", %{conn: conn, user: user} do
      ticker = build_ticker(%{symbol: "WLTEST"})
      build_watchlist_item(%{user_id: user.id, ticker_id: ticker.id})

      {:ok, view, _html} = live(conn, ~p"/")

      Phoenix.PubSub.broadcast(
        LongOrShort.PubSub,
        "prices",
        {:price_tick, "WLTEST", Decimal.new("99.99")}
      )

      assert_push_event view, "price_tick", %{symbol: "WLTEST", price: "99.99"}
    end

    test "empty state links to /watchlist when watchlist is empty", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "Add tickers on"
      assert html =~ ~s|href="/watchlist"|
    end
  end

  describe "search widget" do
    setup %{conn: conn} do
      user = build_trader_user()
      conn = log_in_user(conn, user)
      {:ok, conn: conn, user: user}
    end

    test "returns matching tickers for partial symbol query", %{conn: conn} do
      build_ticker(%{symbol: "NVDA", company_name: "Nvidia Corp"})

      {:ok, view, _html} = live(conn, ~p"/")

      html =
        view
        |> form("#dash-search form", %{query: "NVD"})
        |> render_change()

      assert html =~ "NVDA"
      assert html =~ "Nvidia Corp"
    end

    test "shows no matches message for unrecognised query", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      html =
        view
        |> form("#dash-search form", %{query: "ZZZNOTREAL"})
        |> render_change()

      assert html =~ "No matches"
      refute html =~ ~s|phx-click="select_ticker"|
    end

    test "selecting ticker renders info panel and ticker news", %{conn: conn} do
      ticker = build_ticker(%{symbol: "TSTSYM", company_name: "Test Corp"})
      build_article_for_ticker(ticker, %{title: "Test ticker news"})

      {:ok, view, _html} = live(conn, ~p"/")

      view |> form("#dash-search form", %{query: "TSTSYM"}) |> render_change()

      html =
        view
        |> element("button[phx-click='select_ticker'][phx-value-symbol='TSTSYM']")
        |> render_click()

      assert html =~ "TSTSYM"
      assert html =~ "Test Corp"
      assert html =~ "Test ticker news"
    end

    test "clear_search resets info panel (ESC routes here)", %{conn: conn} do
      ticker = build_ticker(%{symbol: "CLRSYM", company_name: "Clear Corp"})
      build_article_for_ticker(ticker, %{title: "Clear ticker news"})

      {:ok, view, _html} = live(conn, ~p"/")

      view |> form("#dash-search form", %{query: "CLRSYM"}) |> render_change()

      view
      |> element("button[phx-click='select_ticker'][phx-value-symbol='CLRSYM']")
      |> render_click()

      assert render(view) =~ "Clear Corp"

      html = render_click(view, "clear_search")

      refute html =~ "Clear Corp"
      assert html =~ "Search and select a ticker"
    end
  end

  describe "all news widget" do
    setup %{conn: conn} do
      user = build_trader_user()
      conn = log_in_user(conn, user)
      {:ok, conn: conn, user: user}
    end

    test "renders most recent articles via article_card", %{conn: conn} do
      ticker = build_ticker(%{symbol: "AAPL"})
      build_article_for_ticker(ticker, %{title: "Apple does X"})

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "Apple does X"
      assert html =~ ~s|phx-click="analyze"|
    end

    test "limits to 10 articles", %{conn: conn} do
      ticker = build_ticker(%{symbol: "T"})
      for i <- 1..15, do: build_article_for_ticker(ticker, %{title: "Title #{i}"})

      {:ok, _view, html} = live(conn, ~p"/")

      visible = Regex.scan(~r/Title \d+/, html) |> length()
      assert visible <= 10
    end

    test "appends new article on broadcast", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      ticker = build_ticker(%{symbol: "TSLA"})
      article = build_article_for_ticker(ticker, %{title: "Live tesla news"})
      {:ok, article} = News.get_article(article.id, load: [:ticker], authorize?: false)
      News.Events.broadcast_new_article(article)

      assert render(view) =~ "Live tesla news"
    end

    # NOTE: Full analyze workflow test deferred — LON-80 retired the
    # RepetitionAnalyzer and the new NewsAnalyzer (LON-82) plus its UI
    # rewire (LON-83) haven't landed.
    test "clicking Analyze on dashboard shows the rebuild-in-progress flash", %{conn: conn} do
      ticker = build_ticker(%{symbol: "DASH"})
      article = build_article_for_ticker(ticker, %{title: "Dash news"})

      {:ok, view, _html} = live(conn, ~p"/")

      html =
        view
        |> element("button[phx-click='analyze'][phx-value-id='#{article.id}']")
        |> render_click()

      assert html =~ "Analyzer rebuild in progress"
    end

    test "empty state when no articles", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "All news"
      assert html =~ "No news yet"
    end
  end

  describe "watchlist news widget" do
    setup %{conn: conn} do
      user = build_trader_user()
      conn = log_in_user(conn, user)
      {:ok, conn: conn, user: user}
    end

    test "is hidden when watchlist is empty", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      refute html =~ ~s|id="dash-watchlist-news"|
      refute html =~ "My watchlist news"
    end

    test "renders articles only for watchlist tickers", %{conn: conn, user: user} do
      in_watchlist = build_ticker(%{symbol: "INWL"})
      not_in_watchlist = build_ticker(%{symbol: "NOTWL"})

      build_watchlist_item(%{user_id: user.id, ticker_id: in_watchlist.id})

      build_article_for_ticker(in_watchlist, %{title: "Watchlist hit"})
      build_article_for_ticker(not_in_watchlist, %{title: "Not in watchlist"})

      {:ok, _view, html} = live(conn, ~p"/")

      # The watchlist news card section contains only the matching article.
      [_, watchlist_section] = String.split(html, ~s|id="dash-watchlist-news"|)
      assert watchlist_section =~ "Watchlist hit"
      refute watchlist_section =~ "Not in watchlist"
    end

    test "appends new article on broadcast when ticker is in watchlist", %{
      conn: conn,
      user: user
    } do
      ticker = build_ticker(%{symbol: "WLNEW"})
      build_watchlist_item(%{user_id: user.id, ticker_id: ticker.id})

      {:ok, view, _html} = live(conn, ~p"/")

      article = build_article_for_ticker(ticker, %{title: "Live watchlist news"})
      {:ok, article} = News.get_article(article.id, load: [:ticker], authorize?: false)
      News.Events.broadcast_new_article(article)

      html = render(view)
      [_, watchlist_section] = String.split(html, ~s|id="dash-watchlist-news"|)
      assert watchlist_section =~ "Live watchlist news"
    end

    test "ignores broadcast when article ticker is not in watchlist", %{conn: conn, user: user} do
      ticker_in = build_ticker(%{symbol: "WLIN"})
      ticker_out = build_ticker(%{symbol: "WLOUT"})
      build_watchlist_item(%{user_id: user.id, ticker_id: ticker_in.id})

      {:ok, view, _html} = live(conn, ~p"/")

      article = build_article_for_ticker(ticker_out, %{title: "Outside news"})
      {:ok, article} = News.get_article(article.id, load: [:ticker], authorize?: false)
      News.Events.broadcast_new_article(article)

      html = render(view)
      [_, watchlist_section] = String.split(html, ~s|id="dash-watchlist-news"|)
      refute watchlist_section =~ "Outside news"
    end
  end

  describe "watchlist_changed PubSub" do
    setup %{conn: conn} do
      user = build_trader_user()
      conn = log_in_user(conn, user)
      {:ok, conn: conn, user: user}
    end

    test "refreshes watchlist when broadcast received", %{conn: conn, user: user} do
      {:ok, view, html} = live(conn, ~p"/")
      refute html =~ "REFRESHED"

      ticker = build_ticker(%{symbol: "REFRESHED"})
      build_watchlist_item(%{user_id: user.id, ticker_id: ticker.id})
      WatchlistEvents.broadcast_changed(user.id)

      assert render(view) =~ "REFRESHED"
    end

    test "starts rendering watchlist news card after first ticker added", %{
      conn: conn,
      user: user
    } do
      ticker = build_ticker(%{symbol: "POSTADD"})
      build_article_for_ticker(ticker, %{title: "Post-add news"})

      {:ok, view, html} = live(conn, ~p"/")
      refute html =~ ~s|id="dash-watchlist-news"|

      build_watchlist_item(%{user_id: user.id, ticker_id: ticker.id})
      WatchlistEvents.broadcast_changed(user.id)

      html = render(view)
      assert html =~ ~s|id="dash-watchlist-news"|
      assert html =~ "Post-add news"
    end
  end

  describe "indices widget" do
    setup %{conn: conn} do
      user = build_trader_user()
      conn = log_in_user(conn, user)
      {:ok, conn: conn, user: user}
    end

    test "renders three index labels before any tick", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ ~s|id="dash-indices"|
      assert html =~ "DJIA"
      assert html =~ "NASDAQ-100"
      assert html =~ "S&amp;P 500"
    end

    test "renders percent change with success color on positive tick", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      payload = %{
        current: Decimal.new("420.13"),
        change_pct: Decimal.new("0.84"),
        prev_close: Decimal.new("416.62"),
        symbol: "DIA",
        fetched_at: DateTime.utc_now()
      }

      LongOrShort.Indices.Events.broadcast("DJIA", payload)

      html = view |> element("#dash-indices") |> render()
      assert html =~ "0.84%"
      assert html =~ "text-success"
    end

    test "renders error color on negative tick", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      payload = %{
        current: Decimal.new("100"),
        change_pct: Decimal.new("-0.50"),
        prev_close: Decimal.new("100.50"),
        symbol: "QQQ",
        fetched_at: DateTime.utc_now()
      }

      LongOrShort.Indices.Events.broadcast("NASDAQ-100", payload)

      html = view |> element("#dash-indices") |> render()
      assert html =~ "-0.50%"
      assert html =~ "text-error"
    end

    test "neutral tick (|dp| < 0.01) renders without arrow or color class", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      payload = %{
        current: Decimal.new("500"),
        change_pct: Decimal.new("0.005"),
        prev_close: Decimal.new("500"),
        symbol: "SPY",
        fetched_at: DateTime.utc_now()
      }

      LongOrShort.Indices.Events.broadcast("S&P 500", payload)

      html = view |> element("#dash-indices") |> render()
      refute html =~ "text-success"
      refute html =~ "text-error"
      refute html =~ "↑"
      refute html =~ "↓"
    end
  end
end
