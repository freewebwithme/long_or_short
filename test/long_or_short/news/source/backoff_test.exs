defmodule LongOrShort.News.Source.BackoffTest do
  use ExUnit.Case, async: true

  alias LongOrShort.News.Source.Backoff

  describe "next_interval/2" do
    test "returns base_interval when retry_count is 0" do
      assert Backoff.next_interval(1_000, 0) == 1_000
      assert Backoff.next_interval(15_000, 0) == 15_000
    end

    test "doubles each retry (exponential)" do
      assert Backoff.next_interval(1_000, 1) == 2_000
      assert Backoff.next_interval(1_000, 2) == 4_000
      assert Backoff.next_interval(1_000, 3) == 8_000
      assert Backoff.next_interval(1_000, 4) == 16_000
    end

    test "caps at 5 minutes (300_000ms)" do
      # base_interval=15_000, retry=10 → 15_000 * 1024 = 15_360_000
      # capped at 300_000
      assert Backoff.next_interval(15_000, 10) == 300_000

      # extreme retry count still capped
      assert Backoff.next_interval(1_000, 100) == 300_000
    end

    test "honors the cap exactly at the boundary" do
      # 1_000 * 256 = 256_000 < 300_000 → not capped
      assert Backoff.next_interval(1_000, 8) == 256_000

      # 1_000 * 512 = 512_000 > 300_000 → capped
      assert Backoff.next_interval(1_000, 9) == 300_000
    end

    test "raises on negative retry_count" do
      assert_raise FunctionClauseError, fn ->
        Backoff.next_interval(1_000, -1)
      end
    end

    test "raises on zero or negative base_interval" do
      assert_raise FunctionClauseError, fn ->
        Backoff.next_interval(0, 0)
      end

      assert_raise FunctionClauseError, fn ->
        Backoff.next_interval(-100, 0)
      end
    end
  end

  describe "max_interval/0" do
    test "exposes the cap" do
      assert Backoff.max_interval() == :timer.minutes(5)
    end
  end
end
