defmodule LongOrShortWeb.MorningBriefLiveTest do
  @moduledoc """
  Integration tests for the /morning LiveView (LON-129).

  Mirrors the FeedLiveTest pattern (use ConnCase, broadcast directly
  via News.Events rather than spinning the Dummy feeder). Each test
  pins the view mode via `?view=all_recent` so the suite is
  deterministic regardless of wall-clock time.
  """

  use LongOrShortWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import LongOrShort.AccountsFixtures
  import LongOrShort.NewsFixtures
  import LongOrShort.TickersFixtures
  import AshAuthentication.Plug.Helpers, only: [store_in_session: 2]

  alias LongOrShort.News.Events

  defp log_in_user(conn, user) do
    conn
    |> init_test_session(%{})
    |> store_in_session(user)
  end

  describe "authentication" do
    test "unauthenticated request redirects to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/morning")
    end
  end

  describe "render" do
    setup %{conn: conn} do
      user = build_trader_user()
      conn = log_in_user(conn, user)
      {:ok, conn: conn, user: user}
    end

    test "renders Morning Brief heading for an authenticated user", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/morning?view=all_recent")
      assert html =~ "Morning Brief"
    end

    test "shows the empty-state message when no articles are in the window", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/morning?view=opening")
      assert html =~ "No articles in this window"
    end

    test "renders an article that falls inside the current window", %{conn: conn} do
      ticker = build_ticker(%{symbol: "TEST"})

      _article =
        build_article_for_ticker(ticker, %{
          title: "Test catalyst headline",
          published_at: DateTime.add(DateTime.utc_now(), -60, :second)
        })

      {:ok, _live, html} = live(conn, ~p"/morning?view=all_recent")
      assert html =~ "Test catalyst headline"
      assert html =~ "TEST"
    end
  end

  describe "view selector" do
    setup %{conn: conn} do
      user = build_trader_user()
      conn = log_in_user(conn, user)
      {:ok, conn: conn, user: user}
    end

    test "clicking a view button patches the URL", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/morning?view=all_recent")

      view
      |> element("button[phx-value-view=opening]")
      |> render_click()

      assert_patched(view, ~p"/morning?view=opening&focus=all")
    end
  end

  describe "focus toggle" do
    setup %{conn: conn} do
      user = build_trader_user()
      conn = log_in_user(conn, user)
      {:ok, conn: conn, user: user}
    end

    test "the toggle is disabled when the watchlist is empty", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/morning?view=all_recent")
      assert html =~ ~r/<button[^>]+phx-click="toggle_focus"[^>]+disabled/
    end
  end

  describe "PubSub" do
    setup %{conn: conn} do
      user = build_trader_user()
      conn = log_in_user(conn, user)
      {:ok, conn: conn, user: user}
    end

    test "a broadcast inside the current window appears in the stream", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/morning?view=all_recent")

      ticker = build_ticker(%{symbol: "PUSH"})

      article =
        build_article_for_ticker(ticker, %{
          title: "Breaking — live broadcast headline",
          published_at: DateTime.add(DateTime.utc_now(), -10, :second)
        })

      Events.broadcast_new_article(article)

      assert render(view) =~ "Breaking — live broadcast headline"
      assert render(view) =~ "PUSH"
    end

    test "a broadcast outside the current window is dropped", %{conn: conn} do
      # 1-hour `:opening` window — published 2 hours ago must NOT appear.
      {:ok, view, _html} = live(conn, ~p"/morning?view=opening")

      ticker = build_ticker(%{symbol: "DROP"})

      article =
        build_article_for_ticker(ticker, %{
          title: "Out-of-window stale headline",
          published_at: DateTime.add(DateTime.utc_now(), -2 * 3600, :second)
        })

      Events.broadcast_new_article(article)

      refute render(view) =~ "Out-of-window stale headline"
    end
  end
end
