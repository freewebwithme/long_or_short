defmodule LongOrShortWeb.WatchlistLiveTest do
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
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/watchlist")
    end
  end

  describe "render" do
    setup %{conn: conn} do
      user = build_trader_user()
      conn = log_in_user(conn, user)
      {:ok, conn: conn, user: user}
    end

    test "shows empty state when watchlist has no items", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/watchlist")

      assert html =~ "No tickers yet"
    end

    test "renders existing watchlist items with symbol and company name", %{conn: conn, user: user} do
      ticker = build_ticker(%{symbol: "RENDERTEST", company_name: "Render Corp"})
      build_watchlist_item(%{user_id: user.id, ticker_id: ticker.id})

      {:ok, _view, html} = live(conn, ~p"/watchlist")

      assert html =~ "RENDERTEST"
      assert html =~ "Render Corp"
    end

    test "nav highlights Watchlist as active", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/watchlist")

      assert html =~ ~r|href="/watchlist"[^>]*btn-active[^>]*>\s*Watchlist|
      refute html =~ ~r|href="/"[^>]*btn-active|
      refute html =~ ~r|href="/feed"[^>]*btn-active|
    end
  end

  describe "add ticker" do
    setup %{conn: conn} do
      user = build_trader_user()
      conn = log_in_user(conn, user)
      {:ok, conn: conn, user: user}
    end

    test "searching shows suggestions from existing tickers", %{conn: conn} do
      build_ticker(%{symbol: "SRCHTEST", company_name: "Search Corp"})

      {:ok, view, _html} = live(conn, ~p"/watchlist")

      html =
        view
        |> form("form[phx-change='search_ticker']", %{query: "SRCHTEST"})
        |> render_change()

      assert html =~ "SRCHTEST"
      assert html =~ "Search Corp"
    end

    test "clicking a suggestion adds the ticker to the watchlist", %{conn: conn} do
      build_ticker(%{symbol: "ADDTEST", company_name: "Add Corp"})

      {:ok, view, _html} = live(conn, ~p"/watchlist")

      view
      |> form("form[phx-change='search_ticker']", %{query: "ADDTEST"})
      |> render_change()

      html =
        view
        |> element("button[phx-click='add_ticker'][phx-value-symbol='ADDTEST']")
        |> render_click()

      assert html =~ "ADDTEST"
      assert html =~ "Add Corp"
      refute html =~ "No tickers yet"
    end

    test "adding a duplicate shows already-in-watchlist flash", %{conn: conn, user: user} do
      ticker = build_ticker(%{symbol: "DUPTEST"})
      build_watchlist_item(%{user_id: user.id, ticker_id: ticker.id})

      {:ok, view, _html} = live(conn, ~p"/watchlist")

      view
      |> form("form[phx-change='search_ticker']", %{query: "DUPTEST"})
      |> render_change()

      html =
        view
        |> element("button[phx-click='add_ticker'][phx-value-symbol='DUPTEST']")
        |> render_click()

      assert html =~ "already in your watchlist"
    end

    test "clearing search resets suggestions", %{conn: conn} do
      build_ticker(%{symbol: "CLRTEST"})

      {:ok, view, _html} = live(conn, ~p"/watchlist")

      view
      |> form("form[phx-change='search_ticker']", %{query: "CLRTEST"})
      |> render_change()

      html = render_click(view, "clear_search")

      refute html =~ "CLRTEST"
    end
  end

  describe "remove ticker" do
    setup %{conn: conn} do
      user = build_trader_user()
      conn = log_in_user(conn, user)
      {:ok, conn: conn, user: user}
    end

    test "remove button deletes the item and it disappears from the list", %{
      conn: conn,
      user: user
    } do
      ticker = build_ticker(%{symbol: "RMVTEST", company_name: "Remove Corp"})
      item = build_watchlist_item(%{user_id: user.id, ticker_id: ticker.id})

      {:ok, view, html} = live(conn, ~p"/watchlist")
      assert html =~ "RMVTEST"

      html =
        view
        |> element("button[phx-click='remove_ticker'][phx-value-id='#{item.id}']")
        |> render_click()

      refute html =~ "RMVTEST"
      assert html =~ "No tickers yet"
    end

    test "removing one item leaves others intact", %{conn: conn, user: user} do
      ticker_a = build_ticker(%{symbol: "RMVA"})
      ticker_b = build_ticker(%{symbol: "RMVB"})
      item_a = build_watchlist_item(%{user_id: user.id, ticker_id: ticker_a.id})
      _item_b = build_watchlist_item(%{user_id: user.id, ticker_id: ticker_b.id})

      {:ok, view, _html} = live(conn, ~p"/watchlist")

      html =
        view
        |> element("button[phx-click='remove_ticker'][phx-value-id='#{item_a.id}']")
        |> render_click()

      refute html =~ "RMVA"
      assert html =~ "RMVB"
    end
  end
end
