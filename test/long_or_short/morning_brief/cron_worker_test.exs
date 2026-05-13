defmodule LongOrShort.MorningBrief.CronWorkerTest do
  # `async: false` — swaps the global `:morning_brief_provider` config
  # in the `perform/1` integration tests. The `select_bucket/1` unit
  # tests don't need the swap but they share this module's setup so we
  # accept the slower run for simplicity.
  use LongOrShort.DataCase, async: false

  alias LongOrShort.MorningBrief.CronWorker

  # Same Process-dict-stubbed TestProvider pattern as GeneratorTest.
  # Kept inline (not extracted to test_support) because there are
  # exactly two callers and they both live next door.
  defmodule TestProvider do
    @moduledoc false

    def call_with_search(_messages, _opts) do
      case Process.get(:cw_test_response) do
        nil -> raise "TestProvider: no response stubbed"
        response -> response
      end
    end
  end

  setup do
    prior = Application.get_env(:long_or_short, :morning_brief_provider)
    Application.put_env(:long_or_short, :morning_brief_provider, TestProvider)
    on_exit(fn -> Application.put_env(:long_or_short, :morning_brief_provider, prior) end)
    Process.delete(:cw_test_response)
    :ok
  end

  # ── select_bucket/1 — pure function, frozen DateTimes ────────────
  #
  # Fixture dates picked so EDT (UTC-4) gives the expected ET hour.
  # 2026-05-11 is a Monday; 2026-05-09 Saturday; 2026-05-10 Sunday.

  describe "select_bucket/1" do
    test "weekday 05:00 ET → :overnight" do
      # 09:00 UTC - 4h EDT = 05:00 ET on a Monday
      et = ~U[2026-05-11 09:00:00.000000Z] |> DateTime.shift_zone!("America/New_York")
      assert et.hour == 5 and et.minute == 0
      assert CronWorker.select_bucket(et) == :overnight
    end

    test "weekday 08:45 ET → :premarket" do
      et = ~U[2026-05-11 12:45:00.000000Z] |> DateTime.shift_zone!("America/New_York")
      assert et.hour == 8 and et.minute == 45
      assert CronWorker.select_bucket(et) == :premarket
    end

    test "weekday 10:15 ET → :after_open" do
      et = ~U[2026-05-11 14:15:00.000000Z] |> DateTime.shift_zone!("America/New_York")
      assert et.hour == 10 and et.minute == 15
      assert CronWorker.select_bucket(et) == :after_open
    end

    test "weekday outside any of the three windows → nil" do
      # 16:00 UTC = 12:00 ET (Monday lunchtime)
      et = ~U[2026-05-11 16:00:00.000000Z] |> DateTime.shift_zone!("America/New_York")
      assert CronWorker.select_bucket(et) == nil
    end

    test "weekday 05:15 ET (off-the-minute) → nil" do
      # Cron fires at :00 / :15 / :30 / :45 UTC = same ET minutes.
      # Only :00 of hour 5 is overnight; :15 should miss.
      et = ~U[2026-05-11 09:15:00.000000Z] |> DateTime.shift_zone!("America/New_York")
      assert et.hour == 5 and et.minute == 15
      assert CronWorker.select_bucket(et) == nil
    end

    test "saturday matching the time still returns nil" do
      # Saturday May 9 at what would be 05:00 ET
      et = ~U[2026-05-09 09:00:00.000000Z] |> DateTime.shift_zone!("America/New_York")
      assert et.hour == 5 and et.minute == 0
      assert Date.day_of_week(DateTime.to_date(et)) == 6
      assert CronWorker.select_bucket(et) == nil
    end

    test "sunday matching the time still returns nil" do
      et = ~U[2026-05-10 09:00:00.000000Z] |> DateTime.shift_zone!("America/New_York")
      assert Date.day_of_week(DateTime.to_date(et)) == 7
      assert CronWorker.select_bucket(et) == nil
    end
  end

  # ── perform/1 — integration with the test provider ──────────────

  describe "perform/1 with explicit bucket args (test override path)" do
    defp success_response do
      %{
        text: "Test brief body.",
        citations: [],
        usage: %{input_tokens: 100, output_tokens: 50, web_search_requests: 1},
        search_calls: 1
      }
    end

    test "runs the named bucket end-to-end and returns :ok" do
      Process.put(:cw_test_response, {:ok, success_response()})

      assert :ok = CronWorker.perform(%Oban.Job{args: %{"bucket" => "premarket"}})
    end

    test "propagates Generator error so Oban's retry policy kicks in" do
      Process.put(:cw_test_response, {:error, :rate_limited})

      assert {:error, :rate_limited} =
               CronWorker.perform(%Oban.Job{args: %{"bucket" => "overnight"}})
    end

    test "accepts all three bucket strings" do
      Process.put(:cw_test_response, {:ok, success_response()})

      for bucket <- ["overnight", "premarket", "after_open"] do
        assert :ok = CronWorker.perform(%Oban.Job{args: %{"bucket" => bucket}})
      end
    end
  end
end
