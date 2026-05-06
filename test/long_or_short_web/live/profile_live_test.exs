defmodule LongOrShortWeb.ProfileLiveTest do
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
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/profile")
    end
  end

  describe "render" do
    setup %{conn: conn} do
      user = build_trader_user()
      conn = log_in_user(conn, user)
      {:ok, conn: conn, user: user}
    end

    test "renders the placeholder page", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/profile")

      assert html =~ ~s|id="profile-placeholder"|
      assert html =~ "Coming soon"
      assert html =~ "Profile"
    end

    test "user dropdown shows Profile and Settings links alongside Sign out", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/profile")

      assert html =~ ~s|href="/profile"|
      assert html =~ ~s|href="/settings"|
      assert html =~ "Sign out"
    end
  end
end
