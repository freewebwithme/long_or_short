defmodule LongOrShort.RepoTest do
  use LongOrShort.DataCase, async: true

  alias LongOrShort.News
  alias LongOrShort.Repo

  describe "session TimeZone (LON-154)" do
    test "every checked-out connection has TimeZone set to UTC" do
      %{rows: [[tz]]} = Repo.query!("SELECT current_setting('TimeZone')")

      assert tz == "UTC",
             """
             Connection session TZ must be UTC so bare `timestamp without
             time zone` columns compare correctly against timestamptz
             parameters (`now()`, Ash filter `:since` args, etc.). See
             LON-154 for the full bug story.
             """
    end

    test "bare timestamp comparison against now() respects UTC interpretation" do
      # Round-trip a known UTC value through Postgres and ensure the
      # session-level comparison matches what the app expects.
      utc_value = ~U[2026-05-12 20:52:41.000000Z]

      %{rows: [[result]]} =
        Repo.query!(
          "SELECT ($1::timestamp >= (now() - interval '1 hour'))",
          [DateTime.to_naive(utc_value)]
        )

      # 2026-05-12 20:52 UTC is hours-to-days before "now - 1h" at the
      # time this test runs (unless time travel is a feature). With
      # session TZ = UTC the comparison resolves correctly to false.
      # Before the fix this returned true (bare timestamp interpreted
      # as EDT shifted forward by 4h).
      assert result == false
    end
  end

  describe "News.list_morning_brief `:since` filter (LON-154 regression)" do
    import LongOrShort.{NewsFixtures, TickersFixtures}

    test "excludes articles published before the `:since` cutoff" do
      ticker = build_ticker(%{symbol: "TZBUG"})

      # Article 5 hours ago — outside any reasonable view window
      _old =
        build_article_for_ticker(ticker, %{
          title: "Too old",
          published_at: DateTime.add(DateTime.utc_now(), -5 * 3600, :second)
        })

      # Article 5 minutes ago — inside `:opening` (last 60 min)
      _fresh =
        build_article_for_ticker(ticker, %{
          title: "Fresh enough",
          published_at: DateTime.add(DateTime.utc_now(), -300, :second)
        })

      since = DateTime.add(DateTime.utc_now(), -3600, :second)

      {:ok, %Ash.Page.Keyset{results: arts}} =
        News.list_morning_brief(%{since: since},
          load: [:ticker],
          actor: LongOrShort.Accounts.SystemActor.new(),
          page: [limit: 50]
        )

      titles = Enum.map(arts, & &1.title)

      assert "Fresh enough" in titles
      refute "Too old" in titles,
             "expected the 5-hour-old article to be filtered out, but got: #{inspect(titles)}"
    end
  end
end
