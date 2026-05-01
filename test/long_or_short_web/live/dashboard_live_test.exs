defmodule LongOrShortWeb.DashboardLiveTest do
  use LongOrShortWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import LongOrShort.AccountsFixtures
  import AshAuthentication.Plug.Helpers, only: [store_in_session: 2]

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

    test "renders the four placeholder cards", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ ~s|id="dash-search"|
      assert html =~ ~s|id="dash-indices"|
      assert html =~ ~s|id="dash-news"|
      assert html =~ ~s|id="dash-watchlist"|
      assert html =~ "Ticker search"
      assert html =~ "Major indices"
      assert html =~ "Latest news"
      assert html =~ "Watchlist"
    end

    test "nav highlights Dashboard as active", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      # Dashboard link has btn-active
      assert html =~ ~r|href="/"[^>]*btn-active[^>]*>\s*Dashboard|

      # Feed link does NOT have btn-active
      refute html =~ ~r|href="/feed"[^>]*btn-active|
    end
  end
end
