defmodule LongOrShortWeb.SettingsLiveTest do
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
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/settings")
    end
  end

  describe "render" do
    setup %{conn: conn} do
      user = build_trader_user()
      conn = log_in_user(conn, user)
      {:ok, conn: conn, user: user}
    end

    test "renders the three sections", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")

      assert html =~ ~s|id="settings-appearance"|
      assert html =~ ~s|id="settings-notifications"|
      assert html =~ ~s|id="settings-data-sources"|

      assert html =~ "Appearance"
      assert html =~ "Notifications"
      assert html =~ "Data sources"
    end

    test "renders the theme toggle inside Appearance", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")

      assert html =~ ~s|data-phx-theme="system"|
      assert html =~ ~s|data-phx-theme="light"|
      assert html =~ ~s|data-phx-theme="dark"|
    end

    test "Notifications and Data sources are placeholder cards", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")

      assert html =~ "Coming soon"
      # Both placeholder cards carry the muted styling
      assert html =~ ~s|id="settings-notifications" class="card bg-base-200 border border-base-300 p-4 opacity-60"|
      assert html =~ ~s|id="settings-data-sources" class="card bg-base-200 border border-base-300 p-4 opacity-60"|
    end
  end

  describe "navbar" do
    setup %{conn: conn} do
      user = build_trader_user()
      conn = log_in_user(conn, user)
      {:ok, conn: conn, user: user}
    end

    test "theme toggle is no longer rendered in the top nav", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      # The toggle now lives only on /settings; the dashboard's nav must not
      # contain its data-phx-theme attribute.
      refute html =~ ~s|data-phx-theme=|
    end
  end
end
