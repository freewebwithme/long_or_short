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
      assert html =~ "0 articles"
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
      assert html =~ "1 article"
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
      assert html =~ "1 article"
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
      assert html =~ "3 articles"
    end
  end
end
