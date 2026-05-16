defmodule LongOrShort.Research.BriefingFreshnessTest do
  @moduledoc """
  Boundary + DST tests for the LON-174 cache-TTL policy.

  Times are pinned in `"America/New_York"` so `bucket/1` exercises the
  same wall-clock conversion path production uses. We deliberately
  sample both an EDT date (May, UTC-4) and an EST date (January,
  UTC-5) to confirm `DateTime.shift_zone!/2` keeps the bucket math
  stable across the DST transition — the actual conversion happens
  in `et_now/0`, but bucket/ttl_seconds receive a pre-shifted
  `DateTime` so the test surface is the wall-clock interpretation.
  """

  use ExUnit.Case, async: true

  alias LongOrShort.Research.BriefingFreshness

  # ── Bucket classification ───────────────────────────────────────

  describe "bucket/1 — weekday windows (EDT)" do
    test "04:00 ET is the premarket lower boundary" do
      assert BriefingFreshness.bucket(et(~N[2026-05-13 04:00:00])) == :premarket
    end

    test "09:29:59 ET is still premarket" do
      assert BriefingFreshness.bucket(et(~N[2026-05-13 09:29:59])) == :premarket
    end

    test "09:30 ET flips to regular (half-open boundary)" do
      assert BriefingFreshness.bucket(et(~N[2026-05-13 09:30:00])) == :regular
    end

    test "15:59 ET is still regular" do
      assert BriefingFreshness.bucket(et(~N[2026-05-13 15:59:00])) == :regular
    end

    test "16:00 ET flips to after_hours" do
      assert BriefingFreshness.bucket(et(~N[2026-05-13 16:00:00])) == :after_hours
    end

    test "19:59 ET is still after_hours" do
      assert BriefingFreshness.bucket(et(~N[2026-05-13 19:59:00])) == :after_hours
    end

    test "20:00 ET flips to overnight" do
      assert BriefingFreshness.bucket(et(~N[2026-05-13 20:00:00])) == :overnight
    end

    test "02:30 ET is still overnight" do
      assert BriefingFreshness.bucket(et(~N[2026-05-13 02:30:00])) == :overnight
    end

    test "03:59 ET is still overnight (right before premarket)" do
      assert BriefingFreshness.bucket(et(~N[2026-05-13 03:59:00])) == :overnight
    end
  end

  describe "bucket/1 — weekend" do
    test "Saturday morning ignores the weekday window labels" do
      assert BriefingFreshness.bucket(et(~N[2026-05-16 10:00:00])) == :weekend
    end

    test "Sunday afternoon is weekend" do
      assert BriefingFreshness.bucket(et(~N[2026-05-17 15:30:00])) == :weekend
    end

    test "Saturday at the premarket clock hour is still weekend" do
      # Confirms weekend short-circuit beats the 04:00 ET premarket check.
      assert BriefingFreshness.bucket(et(~N[2026-05-16 06:00:00])) == :weekend
    end
  end

  describe "bucket/1 — DST stability (EST month)" do
    test "January weekday, 10:00 ET (EST, UTC-5) classifies as regular" do
      assert BriefingFreshness.bucket(et(~N[2026-01-14 10:00:00])) == :regular
    end

    test "January weekday, 05:30 ET classifies as premarket" do
      assert BriefingFreshness.bucket(et(~N[2026-01-14 05:30:00])) == :premarket
    end
  end

  # ── TTL mapping ─────────────────────────────────────────────────

  describe "ttl_seconds/1" do
    test "premarket → 5 minutes" do
      assert BriefingFreshness.ttl_seconds(et(~N[2026-05-13 06:00:00])) == 5 * 60
    end

    test "regular → 10 minutes" do
      assert BriefingFreshness.ttl_seconds(et(~N[2026-05-13 12:00:00])) == 10 * 60
    end

    test "after_hours → 15 minutes" do
      assert BriefingFreshness.ttl_seconds(et(~N[2026-05-13 17:30:00])) == 15 * 60
    end

    test "overnight → 60 minutes" do
      assert BriefingFreshness.ttl_seconds(et(~N[2026-05-13 22:00:00])) == 60 * 60
    end

    test "weekend → 4 hours" do
      assert BriefingFreshness.ttl_seconds(et(~N[2026-05-16 10:00:00])) == 4 * 60 * 60
    end
  end

  # ── et_now/0 ────────────────────────────────────────────────────

  describe "et_now/0" do
    test "returns a DateTime in America/New_York" do
      now = BriefingFreshness.et_now()
      assert now.time_zone == "America/New_York"
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────

  # Builds an ET-zone `DateTime` from a naive datetime. Keeps the test
  # bodies free of timezone boilerplate.
  defp et(%NaiveDateTime{} = naive) do
    DateTime.from_naive!(naive, "America/New_York")
  end
end
