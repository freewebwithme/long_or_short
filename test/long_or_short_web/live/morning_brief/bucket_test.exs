defmodule LongOrShortWeb.MorningBrief.BucketTest do
  use ExUnit.Case, async: true

  alias LongOrShortWeb.MorningBrief.Bucket

  # Timezone math reminder:
  #
  # EDT (March–November):  ET = UTC - 4
  #   04:00 ET = 08:00 UTC
  #   09:30 ET = 13:30 UTC
  #   10:30 ET = 14:30 UTC
  #   16:00 ET = 20:00 UTC
  #   20:00 ET = 24:00 UTC (= next-day 00:00 UTC)
  #
  # EST (November–March):  ET = UTC - 5
  #   04:00 ET = 09:00 UTC
  #   09:30 ET = 14:30 UTC
  #   16:00 ET = 21:00 UTC
  #
  # All tests inject `now` explicitly so the suite is clock-stable
  # and fast — no `Process.sleep` or `Application.put_env`.

  describe "bucket_for/2 (EDT, May)" do
    # Frozen "now" = 2026-05-11 12:00 UTC = 08:00 ET (premarket window)
    @now ~U[2026-05-11 12:00:00Z]

    test "08:00 ET → :premarket" do
      assert Bucket.bucket_for(~U[2026-05-11 12:00:00Z], @now) == :premarket
    end

    test "exactly 04:00 ET → :premarket (boundary inclusive)" do
      assert Bucket.bucket_for(~U[2026-05-11 08:00:00Z], @now) == :premarket
    end

    test "03:59 ET → :overnight (just below premarket boundary)" do
      assert Bucket.bucket_for(~U[2026-05-11 07:59:00Z], @now) == :overnight
    end

    test "exactly 09:30 ET → :opening (boundary)" do
      assert Bucket.bucket_for(~U[2026-05-11 13:30:00Z], @now) == :opening
    end

    test "09:29 ET → :premarket (right before opening)" do
      assert Bucket.bucket_for(~U[2026-05-11 13:29:00Z], @now) == :premarket
    end

    test "exactly 10:30 ET → :regular (boundary)" do
      assert Bucket.bucket_for(~U[2026-05-11 14:30:00Z], @now) == :regular
    end

    test "exactly 16:00 ET → :afterhours (boundary)" do
      assert Bucket.bucket_for(~U[2026-05-11 20:00:00Z], @now) == :afterhours
    end

    test "exactly 20:00 ET → :other (afterhours upper bound exclusive)" do
      assert Bucket.bucket_for(~U[2026-05-12 00:00:00Z], @now) == :other
    end

    test "yesterday 18:00 ET → :overnight (within prev-day 16:00 → today 04:00)" do
      published = ~U[2026-05-10 22:00:00Z]
      assert Bucket.bucket_for(published, @now) == :overnight
    end

    test "yesterday 14:00 ET → :other (before overnight window starts)" do
      published = ~U[2026-05-10 18:00:00Z]
      assert Bucket.bucket_for(published, @now) == :other
    end
  end

  describe "bucket_for/2 (EST, January)" do
    @now ~U[2026-01-15 13:00:00Z]

    test "EST 09:30 ET → :opening" do
      assert Bucket.bucket_for(~U[2026-01-15 14:30:00Z], @now) == :opening
    end

    test "EST 04:00 ET → :premarket" do
      assert Bucket.bucket_for(~U[2026-01-15 09:00:00Z], @now) == :premarket
    end

    test "EST 16:00 ET → :afterhours" do
      assert Bucket.bucket_for(~U[2026-01-15 21:00:00Z], @now) == :afterhours
    end
  end

  describe "default_view_for/1" do
    test "04:00 ET → :premarket_brief" do
      assert Bucket.default_view_for(~U[2026-05-11 08:00:00Z]) == :premarket_brief
    end

    test "09:29 ET → :premarket_brief" do
      assert Bucket.default_view_for(~U[2026-05-11 13:29:00Z]) == :premarket_brief
    end

    test "09:30 ET → :opening" do
      assert Bucket.default_view_for(~U[2026-05-11 13:30:00Z]) == :opening
    end

    test "10:29 ET → :opening" do
      assert Bucket.default_view_for(~U[2026-05-11 14:29:00Z]) == :opening
    end

    test "10:30 ET → :intraday" do
      assert Bucket.default_view_for(~U[2026-05-11 14:30:00Z]) == :intraday
    end

    test "15:59 ET → :intraday" do
      assert Bucket.default_view_for(~U[2026-05-11 19:59:00Z]) == :intraday
    end

    test "16:00 ET → :afterhours" do
      assert Bucket.default_view_for(~U[2026-05-11 20:00:00Z]) == :afterhours
    end

    test "19:59 ET → :afterhours" do
      assert Bucket.default_view_for(~U[2026-05-11 23:59:00Z]) == :afterhours
    end

    test "20:00 ET → :all_recent (after-hours upper bound)" do
      assert Bucket.default_view_for(~U[2026-05-12 00:00:00Z]) == :all_recent
    end

    test "03:00 ET → :all_recent (early-morning fallthrough)" do
      assert Bucket.default_view_for(~U[2026-05-11 07:00:00Z]) == :all_recent
    end

    test "EST 04:00 ET (January) → :premarket_brief" do
      assert Bucket.default_view_for(~U[2026-01-15 09:00:00Z]) == :premarket_brief
    end
  end

  describe "view_window/2" do
    test ":premarket_brief starts prev-day 16:00 ET" do
      now = ~U[2026-05-11 13:00:00Z]
      {since, until} = Bucket.view_window(:premarket_brief, now)
      assert since == ~U[2026-05-10 20:00:00Z]
      assert until == now
    end

    test ":opening is the last 60 minutes" do
      now = ~U[2026-05-11 13:30:00Z]
      {since, until} = Bucket.view_window(:opening, now)
      assert DateTime.diff(until, since, :second) == 3600
      assert until == now
    end

    test ":intraday is the last 4 hours" do
      now = ~U[2026-05-11 15:00:00Z]
      {since, until} = Bucket.view_window(:intraday, now)
      assert DateTime.diff(until, since, :second) == 4 * 3600
      assert until == now
    end

    test ":afterhours starts today 16:00 ET" do
      now = ~U[2026-05-11 22:00:00Z]
      {since, until} = Bucket.view_window(:afterhours, now)
      assert since == ~U[2026-05-11 20:00:00Z]
      assert until == now
    end

    test ":all_recent is the last 24 hours" do
      now = ~U[2026-05-11 13:00:00Z]
      {since, until} = Bucket.view_window(:all_recent, now)
      assert DateTime.diff(until, since, :second) == 24 * 3600
      assert until == now
    end
  end

  describe "DST edge cases" do
    test "spring-forward day (2026-03-08): bucket_for still works at 04:00 EDT" do
      now = ~U[2026-03-08 12:00:00Z]
      assert Bucket.bucket_for(~U[2026-03-08 08:00:00Z], now) == :premarket
    end

    test "fall-back day (2026-11-01): bucket_for still works at 04:00 EST" do
      now = ~U[2026-11-01 13:00:00Z]
      assert Bucket.bucket_for(~U[2026-11-01 09:00:00Z], now) == :premarket
    end
  end

  describe "et_now/0" do
    test "returns a DateTime in America/New_York" do
      dt = Bucket.et_now()
      assert dt.time_zone == "America/New_York"
    end
  end
end
