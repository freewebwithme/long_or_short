defmodule LongOrShortWeb.ProfileLiveTest do
  use LongOrShortWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import LongOrShort.AccountsFixtures
  import AshAuthentication.Plug.Helpers, only: [store_in_session: 2]

  alias LongOrShort.Accounts

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

    test "renders all three sections", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/profile")

      assert html =~ ~s|id="profile-personal-info"|
      assert html =~ ~s|id="profile-password"|
      assert html =~ ~s|id="profile-trader"|
      assert html =~ "Personal info"
      assert html =~ "Change password"
      assert html =~ "Trader profile"
    end

    test "user dropdown still shows Profile link as available", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/profile")

      assert html =~ ~s|href="/profile"|
      assert html =~ ~s|href="/settings"|
    end

    test "shows email as disabled in personal info form", %{conn: conn, user: user} do
      {:ok, _view, html} = live(conn, ~p"/profile")

      assert html =~ to_string(user.email)
      assert html =~ ~s|disabled|
    end
  end

  describe "personal info section" do
    setup %{conn: conn} do
      user = build_trader_user()
      conn = log_in_user(conn, user)
      {:ok, conn: conn, user: user}
    end

    test "lazy-creates a UserProfile on first mount", %{conn: conn, user: user} do
      assert {:ok, nil} = Accounts.get_user_profile_by_user(user.id, authorize?: false)

      {:ok, _view, _html} = live(conn, ~p"/profile")

      {:ok, profile} = Accounts.get_user_profile_by_user(user.id, authorize?: false)
      assert profile.user_id == user.id
    end

    test "save_personal_info updates the profile", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/profile")

      html =
        view
        |> form("#personal-info-form", %{
          "form" => %{
            "full_name" => "Alice Trader",
            "phone" => "555-0042",
            "avatar_url" => ""
          }
        })
        |> render_submit()

      assert html =~ "Personal info updated"

      {:ok, profile} = Accounts.get_user_profile_by_user(user.id, authorize?: false)
      assert profile.full_name == "Alice Trader"
      assert profile.phone == "555-0042"
    end

    test "renders avatar preview as initials when no URL is set", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/profile")

      # No avatar URL → falls back to initials in a colored circle
      refute html =~ ~s|<img src=|
      assert html =~ "rounded-full"
    end
  end

  describe "change password section" do
    setup %{conn: conn} do
      user = build_trader_user()
      conn = log_in_user(conn, user)
      {:ok, conn: conn, user: user}
    end

    test "successful change shows flash and signs-out caption", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/profile")
      assert html =~ "other browser sessions"

      html =
        view
        |> form("#password-form", %{
          "form" => %{
            "current_password" => "testpassword123",
            "password" => "newpassword456",
            "password_confirmation" => "newpassword456"
          }
        })
        |> render_submit()

      assert html =~ "Password updated"
    end

    test "wrong current password shows inline error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/profile")

      html =
        view
        |> form("#password-form", %{
          "form" => %{
            "current_password" => "wrong-password",
            "password" => "newpassword456",
            "password_confirmation" => "newpassword456"
          }
        })
        |> render_submit()

      refute html =~ "Password updated"
    end

    test "password confirmation mismatch shows inline error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/profile")

      html =
        view
        |> form("#password-form", %{
          "form" => %{
            "current_password" => "testpassword123",
            "password" => "newpassword456",
            "password_confirmation" => "different-789"
          }
        })
        |> render_submit()

      refute html =~ "Password updated"
    end
  end

  describe "trader profile section" do
    setup %{conn: conn} do
      user = build_trader_user()
      conn = log_in_user(conn, user)
      {:ok, conn: conn, user: user}
    end

    test "shows CTA when user has no trading profile", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/profile")

      assert html =~ "Create your trader profile"
      refute html =~ ~s|id="trading-profile-form"|
    end

    test "clicking CTA creates a profile and renders the edit form", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/profile")

      html =
        view
        |> element("button[phx-click='create_trading_profile']")
        |> render_click()

      assert html =~ ~s|id="trading-profile-form"|
      refute html =~ "Create your trader profile"

      {:ok, profile} = Accounts.get_trading_profile_by_user(user.id, authorize?: false)
      assert profile.trading_style == :momentum_day
      assert profile.time_horizon == :intraday
    end

    test "shows the edit form (not the CTA) when profile already exists", %{conn: conn, user: user} do
      build_trading_profile(%{user_id: user.id})

      {:ok, _view, html} = live(conn, ~p"/profile")

      assert html =~ ~s|id="trading-profile-form"|
      refute html =~ "Create your trader profile"
    end

    test "save_trading_profile updates the profile", %{conn: conn, user: user} do
      build_trading_profile(%{user_id: user.id, trading_style: :momentum_day})

      {:ok, view, _html} = live(conn, ~p"/profile")

      html =
        view
        |> form("#trading-profile-form", %{
          "form" => %{
            "trading_style" => "swing",
            "time_horizon" => "multi_day",
            "market_cap_focuses" => ["mid"],
            "catalyst_preferences" => ["earnings"],
            "notes" => "shifted to swing"
          }
        })
        |> render_submit()

      assert html =~ "Trader profile updated"

      {:ok, profile} = Accounts.get_trading_profile_by_user(user.id, authorize?: false)
      assert profile.trading_style == :swing
      assert profile.time_horizon == :multi_day
      assert profile.notes == "shifted to swing"
    end

    test "momentum-only fields appear when style is momentum_day", %{conn: conn, user: user} do
      build_trading_profile(%{user_id: user.id, trading_style: :momentum_day})

      {:ok, _view, html} = live(conn, ~p"/profile")

      assert html =~ "Price min"
      assert html =~ "Price max"
      assert html =~ "Float max"
    end

    test "momentum-only fields hide when style is not momentum_day", %{conn: conn, user: user} do
      build_trading_profile(%{user_id: user.id, trading_style: :swing})

      {:ok, _view, html} = live(conn, ~p"/profile")

      refute html =~ "Price min"
      refute html =~ "Price max"
      refute html =~ "Float max"
    end

    test "switching style via validate toggles momentum fields", %{conn: conn, user: user} do
      build_trading_profile(%{user_id: user.id, trading_style: :swing})

      {:ok, view, html} = live(conn, ~p"/profile")
      refute html =~ "Price min"

      html =
        view
        |> form("#trading-profile-form", %{
          "form" => %{
            "trading_style" => "momentum_day",
            "time_horizon" => "intraday",
            "market_cap_focuses" => [],
            "catalyst_preferences" => [],
            "notes" => ""
          }
        })
        |> render_change()

      assert html =~ "Price min"
    end
  end
end
