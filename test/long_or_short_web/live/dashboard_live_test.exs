defmodule LongOrShortWeb.DashboardLiveTest do
  use LongOrShortWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import LongOrShort.{AccountsFixtures, TickersFixtures}
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

  describe "watchlist widget" do
    setup %{conn: conn} do
      user = build_trader_user()
      conn = log_in_user(conn, user)
      {:ok, conn: conn, user: user}
    end

    test "renders symbols from watchlist with PriceLabel hooks", %{conn: conn} do
      Application.put_env(:long_or_short, :watchlist_override, ~w(AAPL TSLA))
      on_exit(fn -> Application.delete_env(:long_or_short, :watchlist_override) end)

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "AAPL"
      assert html =~ "TSLA"
      assert html =~ ~s|phx-hook="PriceLabel"|
      assert html =~ ~s|data-symbol="AAPL"|
      assert html =~ ~s|data-symbol="TSLA"|
    end

    test "shows initial price when ticker has last_price", %{conn: conn} do
      Application.put_env(:long_or_short, :watchlist_override, ["WLTEST"])
      on_exit(fn -> Application.delete_env(:long_or_short, :watchlist_override) end)

      build_ticker(%{symbol: "WLTEST", last_price: Decimal.new("42.50")})

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ ~s|data-initial-price="42.50"|
    end

    test "leaves data-initial-price empty when ticker missing or no last_price", %{conn: conn} do
      Application.put_env(:long_or_short, :watchlist_override, ["NOPRICE"])
      on_exit(fn -> Application.delete_env(:long_or_short, :watchlist_override) end)

      build_ticker(%{symbol: "NOPRICE"})

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ ~s|data-symbol="NOPRICE"|
      assert html =~ ~s|data-initial-price=""|
    end

    test "pushes price_tick event on PubSub broadcast", %{conn: conn} do
      Application.put_env(:long_or_short, :watchlist_override, ["WLTEST"])
      on_exit(fn -> Application.delete_env(:long_or_short, :watchlist_override) end)

      build_ticker(%{symbol: "WLTEST"})

      {:ok, view, _html} = live(conn, ~p"/")

      Phoenix.PubSub.broadcast(
        LongOrShort.PubSub,
        "prices",
        {:price_tick, "WLTEST", Decimal.new("99.99")}
      )

      assert_push_event view, "price_tick", %{symbol: "WLTEST", price: "99.99"}
    end

    test "empty state when watchlist is empty", %{conn: conn} do
      Application.put_env(:long_or_short, :watchlist_override, [])
      on_exit(fn -> Application.delete_env(:long_or_short, :watchlist_override) end)

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "Add symbols to"
      assert html =~ "watchlist.txt"
    end
  end
end
