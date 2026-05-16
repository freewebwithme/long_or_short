defmodule LongOrShortWeb.ScoutLiveTest do
  @moduledoc """
  Tests for `/scout` and `/scout/:symbol` (LON-173, PT-2).

  Strategy: drive the LiveView through Phoenix.LiveViewTest, simulate
  the PubSub callbacks directly by sending the well-defined
  `LongOrShort.Research.Events` messages to the LiveView pid. The
  underlying `BriefingWorker` is exercised separately in
  `LongOrShort.Research.Workers.BriefingWorkerTest` — this file only
  cares about the UI state machine.
  """

  use LongOrShortWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import LongOrShort.AccountsFixtures
  import LongOrShort.TickersFixtures
  import AshAuthentication.Plug.Helpers, only: [store_in_session: 2]

  alias LongOrShort.Research

  defp log_in_user(conn, user) do
    conn
    |> init_test_session(%{})
    |> store_in_session(user)
  end

  defp user_with_profile do
    # `build_trader_user/0` returns the auth-enabled user struct with
    # the token field `store_in_session/2` needs — don't re-fetch via
    # `Ash.get/2`, which strips it. The LiveView's
    # `:preload_trading_profile` on_mount hook (router.ex) loads the
    # profile into `socket.assigns.current_user.trading_profile`.
    user = build_trader_user()
    _profile = build_trading_profile(%{user_id: user.id})
    user
  end

  defp seed_briefing(user, symbol, overrides \\ %{}) do
    ticker =
      Map.get_lazy(overrides, :ticker, fn ->
        # Reuse the existing ticker if the test already built one for
        # this symbol (e.g. the `/scout/:symbol` cache-miss setup).
        # Otherwise create.
        case LongOrShort.Tickers.get_ticker_by_symbol(symbol, authorize?: false) do
          {:ok, t} -> t
          _ -> build_ticker(%{symbol: symbol})
        end
      end)

    attrs =
      Map.merge(
        %{
          symbol: symbol,
          narrative: "## TL;DR\n\nWatch — preseeded briefing for #{symbol}.",
          citations: [],
          provider: :mock,
          model: "mock-sonnet",
          usage: %{},
          cached_until: DateTime.add(DateTime.utc_now(), 600, :second),
          trading_profile_snapshot: %{},
          ticker_id: ticker.id,
          generated_for_user_id: user.id
        },
        Map.drop(overrides, [:ticker])
      )

    {:ok, b} = Research.upsert_ticker_briefing(attrs, authorize?: false)
    b
  end

  # ── Auth ────────────────────────────────────────────────────────

  describe "auth" do
    test "unauthenticated /scout redirects to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/scout")
    end
  end

  # ── /scout index ────────────────────────────────────────────────

  describe "/scout (index)" do
    setup %{conn: conn} do
      user = user_with_profile()
      {:ok, conn: log_in_user(conn, user), user: user}
    end

    test "renders the empty state when no symbol is locked", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/scout")
      assert html =~ "Pick a ticker to scout"
      # The Run Scout button is not rendered when no symbol is locked —
      # but the empty-state copy mentions the button by name, so we
      # refute the phx-click handler instead of the literal string.
      refute html =~ ~s|phx-click="run_scout"|
    end

    test "renders the recent scouts panel — empty initially", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/scout")
      assert html =~ "Recent scouts"
      assert html =~ "No scouts yet"
    end

    test "renders existing briefings in the recent scouts panel", %{conn: conn, user: user} do
      briefing = seed_briefing(user, "PANEL")

      {:ok, _live, html} = live(conn, ~p"/scout")
      assert html =~ "PANEL"
      # Recent-scouts panel links to the detail page (`/scout/b/:id`) so
      # stale briefings render their content; symbol-routed pages would
      # fall back to `:ready` for an expired cache. See ScoutDetailLive.
      assert html =~ "/scout/b/#{briefing.id}"
    end
  end

  # ── /scout/:symbol — cache hit ──────────────────────────────────

  describe "/scout/:symbol — cache hit path" do
    setup %{conn: conn} do
      user = user_with_profile()
      {:ok, conn: log_in_user(conn, user), user: user}
    end

    test "fresh cached briefing renders the result card immediately", %{conn: conn, user: user} do
      seed_briefing(user, "CACHE")

      {:ok, _live, html} = live(conn, ~p"/scout/CACHE")

      assert html =~ "preseeded briefing for CACHE"
      assert html =~ "fresh"
      # Status bar should NOT be visible
      refute html =~ "Scouting CACHE…"
    end
  end

  # ── /scout/:symbol — cache miss → Run → ready ───────────────────

  describe "/scout/:symbol — cache miss path" do
    setup %{conn: conn} do
      user = user_with_profile()
      _ticker = build_ticker(%{symbol: "MISS"})
      {:ok, conn: log_in_user(conn, user), user: user}
    end

    test "shows the Run Scout button + ready state when no fresh briefing exists", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/scout/MISS")
      assert html =~ "Run Scout"
      assert html =~ "No cached briefing for"
    end

    test "Run Scout click flips to running status + shows status bar", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/scout/MISS")

      html = render_click(live, "run_scout", %{})

      assert html =~ "Scouting MISS…"
      assert html =~ "Pulling SEC filings"
    end

    test "broadcasting :briefing_ready swaps the UI to the result card", %{
      conn: conn,
      user: user
    } do
      {:ok, live, _html} = live(conn, ~p"/scout/MISS")
      _html = render_click(live, "run_scout", %{})

      # Capture the request_id assigned by the worker enqueue path
      %{active_request_id: request_id} = :sys.get_state(live.pid).socket.assigns
      assert is_binary(request_id)

      # Generator wrote a row — simulate it for the test.
      briefing = seed_briefing(user, "MISS")

      send(
        live.pid,
        {:briefing_ready, briefing.ticker_id, briefing.id, request_id}
      )

      html = render(live)
      assert html =~ "preseeded briefing for MISS"
      refute html =~ "Scouting MISS…"
    end

    test "broadcasting :briefing_failed flips to the error + retry CTA", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/scout/MISS")
      _ = render_click(live, "run_scout", %{})
      %{active_request_id: request_id} = :sys.get_state(live.pid).socket.assigns

      send(live.pid, {:briefing_failed, nil, :provider_unavailable, request_id})

      html = render(live)
      assert html =~ "Scout for MISS failed"
      assert html =~ "Retry"
    end
  end

  # ── No TradingProfile gate ──────────────────────────────────────

  describe "/scout/:symbol — no profile gate" do
    test "trader without a profile sees the Setup CTA + disabled button", %{conn: conn} do
      user = build_trader_user()
      conn = log_in_user(conn, user)
      _ticker = build_ticker(%{symbol: "GATE"})

      {:ok, _live, html} = live(conn, ~p"/scout/GATE")

      assert html =~ "Setup your trader profile first"
      # Button is rendered but disabled
      assert html =~ "Run Scout"
    end
  end

  # ── Mid-run ticker switch ───────────────────────────────────────

  describe "mid-run safety" do
    setup %{conn: conn} do
      user = user_with_profile()
      _t = build_ticker(%{symbol: "OLD"})
      _t2 = build_ticker(%{symbol: "NEW"})
      {:ok, conn: log_in_user(conn, user), user: user}
    end

    test "late :briefing_ready for previous request_id is ignored", %{conn: conn, user: user} do
      {:ok, live, _html} = live(conn, ~p"/scout/OLD")
      _ = render_click(live, "run_scout", %{})

      # Switch to NEW before the OLD job's result arrives
      {:ok, live, _html} = live(conn, ~p"/scout/NEW")

      # Simulate the stale OLD result arriving on the new socket
      stale_briefing = seed_briefing(user, "OLD")

      send(
        live.pid,
        {:briefing_ready, stale_briefing.ticker_id, stale_briefing.id, "stale-request-id"}
      )

      html = render(live)
      # OLD briefing content must not bleed into the NEW view
      refute html =~ "preseeded briefing for OLD"
    end
  end
end
