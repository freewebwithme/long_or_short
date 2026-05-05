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
  import LongOrShort.TickersFixtures
  import AshAuthentication.Plug.Helpers, only: [store_in_session: 2]

  alias LongOrShort.News
  alias LongOrShort.News.Events

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

  # NOTE: Full analyze workflow tests deferred — LON-80 retired the
  # RepetitionAnalyzer and the new NewsAnalyzer (LON-82) plus its UI
  # rewire (LON-83) haven't landed. During the gap the Analyze button
  # is visible but shows a flash on click.
  describe "analyze button — LON-80 rebuild gap" do
    setup %{conn: conn} do
      user = build_trader_user()
      conn = log_in_user(conn, user)
      {:ok, conn: conn, user: user}
    end

    test "renders Analyze button on every article", %{conn: conn} do
      ticker = build_ticker(%{symbol: "AAPL"})
      build_article_for_ticker(ticker, %{title: "Apple Q2"})

      {:ok, _view, html} = live(conn, ~p"/feed")

      assert html =~ "Analyze"
      assert html =~ ~s|phx-click="analyze"|
    end

    test "clicking Analyze shows the rebuild-in-progress flash", %{conn: conn} do
      ticker = build_ticker(%{symbol: "BTBD"})
      article = build_article_for_ticker(ticker, %{title: "BTBD news"})

      {:ok, view, _html} = live(conn, ~p"/feed")

      html =
        view
        |> element("button[phx-click='analyze'][phx-value-id='#{article.id}']")
        |> render_click()

      assert html =~ "Analyzer rebuild in progress"
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
end
