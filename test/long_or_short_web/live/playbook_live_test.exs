defmodule LongOrShortWeb.PlaybookLiveTest do
  @moduledoc """
  Tests for `/playbook` (LON-184) — the read-only Playbook view.

  Companion edit-side coverage lives in `PlaybookEditLiveTest`.
  """

  use LongOrShortWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import LongOrShort.AccountsFixtures
  import LongOrShort.TradingFixtures
  import AshAuthentication.Plug.Helpers, only: [store_in_session: 2]

  defp log_in_user(conn, user) do
    conn
    |> init_test_session(%{})
    |> store_in_session(user)
  end

  describe "/playbook — empty state" do
    test "renders the empty-state card with a 'Create your first playbook' CTA", %{conn: conn} do
      conn = log_in_user(conn, build_trader_user())

      {:ok, _live, html} = live(conn, ~p"/playbook")

      assert html =~ "No playbooks yet"
      assert html =~ "Create your first playbook"
      assert html =~ ~s|href="/playbook/edit"|
    end
  end

  describe "/playbook — populated" do
    setup %{conn: conn} do
      user = build_trader_user()

      build_playbook(%{
        user_id: user.id,
        kind: :rules,
        name: "Daily rules",
        items: [%{text: "Daily max loss $160"}, %{text: "No revenge trades"}]
      })

      build_playbook(%{
        user_id: user.id,
        kind: :setup,
        name: "Long setup",
        items: [%{text: "Price $2-$10"}, %{text: "Catalyst present"}]
      })

      {:ok, conn: log_in_user(conn, user)}
    end

    test "shows Daily Rules + Setups sections with their items", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/playbook")

      assert html =~ "Daily Rules"
      assert html =~ "Daily rules"
      assert html =~ "Daily max loss $160"
      assert html =~ "No revenge trades"

      assert html =~ "Setups"
      assert html =~ "Long setup"
      assert html =~ "Price $2-$10"
      assert html =~ "Catalyst present"

      # Version chip + item count
      assert html =~ "v1"
      assert html =~ "2 items"
    end

    test "Edit button navigates to /playbook/edit", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/playbook")

      assert live |> element("a", "Edit") |> render_click() |> follow_redirect(conn, "/playbook/edit")
    end

    test "does not show another user's playbooks", %{conn: conn} do
      other = build_trader_user()

      build_playbook(%{
        user_id: other.id,
        name: "OtherSecretRules",
        items: [%{text: "ZZZ_INTRUDER_RULE_TEXT"}]
      })

      {:ok, _live, html} = live(conn, ~p"/playbook")

      refute html =~ "OtherSecretRules"
      refute html =~ "ZZZ_INTRUDER_RULE_TEXT"
    end
  end

  describe "/playbook — rules-only or setups-only" do
    test "rules-only user → no orphan 'Setups' header", %{conn: conn} do
      user = build_trader_user()

      build_playbook(%{
        user_id: user.id,
        kind: :rules,
        name: "Daily rules",
        items: [%{text: "rule A"}]
      })

      {:ok, _live, html} = live(log_in_user(conn, user), ~p"/playbook")

      assert html =~ "Daily Rules"
      refute html =~ "Setups"
    end
  end
end
