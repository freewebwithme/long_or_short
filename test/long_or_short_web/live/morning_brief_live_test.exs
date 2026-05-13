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

  # ── LON-152: Brief card ─────────────────────────────────────────

  describe "brief card" do
    setup %{conn: conn} do
      user = build_trader_user()
      conn = log_in_user(conn, user)
      {:ok, conn: conn, user: user}
    end

    defp et_today do
      DateTime.utc_now()
      |> DateTime.shift_zone!("America/New_York")
      |> DateTime.to_date()
    end

    defp build_digest(overrides \\ %{}) do
      attrs =
        Map.merge(
          %{
            bucket_date: et_today(),
            bucket: :premarket,
            content: "# 시황 요약\n\n오늘 CPI 발표 후 시장 약세 [1].",
            citations: [
              %{
                idx: 1,
                url: "https://www.cnbc.com/x",
                title: "CNBC X",
                source: "cnbc.com",
                cited_text: "snip",
                accessed_at: DateTime.utc_now()
              }
            ],
            llm_provider: :anthropic,
            llm_model: "claude-haiku-4-5-20251001",
            input_tokens: 1000,
            output_tokens: 200,
            search_calls: 1,
            raw_response: %{"sample" => true}
          },
          overrides
        )

      {:ok, digest} = LongOrShort.Analysis.upsert_digest(attrs, authorize?: false)
      digest
    end

    test "renders the fresh brief card with markdown + citations when today's digest exists",
         %{conn: conn} do
      build_digest()

      {:ok, _view, html} = live(conn, ~p"/morning?view=all_recent")

      # New brief-card surface
      assert html =~ ~s|id="morning-brief-card"|
      # Markdown rendered (the `#` heading turned into <h1>)
      assert html =~ "시황 요약"
      # Citations section
      assert html =~ "Sources"
      assert html =~ "cnbc.com"
      assert html =~ "CNBC X"
      # External-link confirm pattern reused
      assert html =~ "외부 링크로 이동합니다"
    end

    test "clicking a bucket tab swaps the visible digest", %{conn: conn} do
      build_digest(%{bucket: :overnight, content: "OVERNIGHT-UNIQUE-MARKER"})
      build_digest(%{bucket: :premarket, content: "PREMARKET-UNIQUE-MARKER"})

      {:ok, view, _html} = live(conn, ~p"/morning?view=all_recent")

      html =
        view
        |> element("button[phx-click='select_bucket'][phx-value-bucket='overnight']")
        |> render_click()

      assert html =~ "OVERNIGHT-UNIQUE-MARKER"
      refute html =~ "PREMARKET-UNIQUE-MARKER"
    end

    test "shows stale banner when today's bucket is missing but a prior digest exists",
         %{conn: conn} do
      yesterday = Date.add(et_today(), -1)
      build_digest(%{bucket_date: yesterday, content: "STALE-FALLBACK-MARKER"})

      {:ok, _view, html} = live(conn, ~p"/morning?view=all_recent")

      assert html =~ "마지막 캐시"
      assert html =~ "STALE-FALLBACK-MARKER"
    end

    test "shows empty state when no digest exists at all", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/morning?view=all_recent")

      assert html =~ "곧 준비됩니다"
    end

    test "regression: article list and view selector still render alongside the brief card",
         %{conn: conn} do
      ticker = build_ticker(%{symbol: "REGR"})

      build_article_for_ticker(ticker, %{
        title: "Regression article",
        published_at: DateTime.add(DateTime.utc_now(), -60, :second)
      })

      build_digest()

      {:ok, _view, html} = live(conn, ~p"/morning?view=all_recent")

      assert html =~ ~s|id="morning-brief-card"|
      assert html =~ ~s|id="morning-articles"|
      assert html =~ "Regression article"
      assert html =~ "REGR"
      # Existing view selector still present
      assert html =~ "Premarket Brief"
      assert html =~ "All Recent (24h)"
    end
  end

  # ── LON-153: multi-ticker dedup ─────────────────────────────────

  describe "article dedup (multi-ticker)" do
    setup %{conn: conn} do
      user = build_trader_user()
      conn = log_in_user(conn, user)
      {:ok, conn: conn, user: user}
    end

    test "collapses rows sharing (source, external_id) into one row with multiple ticker badges",
         %{conn: conn} do
      oklo = build_ticker(%{symbol: "OKLO"})
      tsla = build_ticker(%{symbol: "TSLA"})
      sndk = build_ticker(%{symbol: "SNDK"})

      now = DateTime.add(DateTime.utc_now(), -60, :second)

      shared = %{
        title: "MULTI-TICKER-HEADLINE",
        external_id: "ext-shared-42",
        source: "alpaca",
        published_at: now
      }

      build_article_for_ticker(oklo, shared)
      build_article_for_ticker(tsla, shared)
      build_article_for_ticker(sndk, shared)

      {:ok, _view, html} = live(conn, ~p"/morning?view=all_recent")

      # Single headline row, not 3
      assert html =~ "MULTI-TICKER-HEADLINE"
      occurrences = Regex.scan(~r/MULTI-TICKER-HEADLINE/, html) |> length()
      assert occurrences == 1, "headline appeared #{occurrences} times, expected 1"

      # All 3 ticker badges rendered
      assert html =~ "OKLO"
      assert html =~ "TSLA"
      assert html =~ "SNDK"
    end

    test "same external_id but different sources stays as separate rows", %{conn: conn} do
      t = build_ticker(%{symbol: "DIST"})

      now = DateTime.add(DateTime.utc_now(), -60, :second)

      build_article_for_ticker(t, %{
        title: "ALPACA-HEAD",
        external_id: "common-id-99",
        source: "alpaca",
        published_at: now
      })

      build_article_for_ticker(t, %{
        title: "FINNHUB-HEAD",
        external_id: "common-id-99",
        source: "finnhub",
        published_at: now
      })

      {:ok, _view, html} = live(conn, ~p"/morning?view=all_recent")

      # Both source-specific rows visible
      assert html =~ "ALPACA-HEAD"
      assert html =~ "FINNHUB-HEAD"
    end
  end
end
