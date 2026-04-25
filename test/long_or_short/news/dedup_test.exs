defmodule LongOrShort.News.DedupTest do
  @moduledoc """
  Unit tests for `LongOrShort.News.Dedup`.

  Not async — Dedup uses a named, public ETS table and a globally
  named GenServer, both of which are shared resources. Tests start
  the GenServer with `start_supervised!` and clear the table in
  `setup` so each test starts from a clean state.
  """

  use ExUnit.Case, async: false

  alias LongOrShort.News.Dedup

  setup do
    Dedup.clear()
    :ok
  end

  describe "check_and_mark/3" do
    test "returns true on first sight, false on repeat" do
      assert Dedup.check_and_mark(:benzinga, "abc-123", "BTBD") == true
      assert Dedup.check_and_mark(:benzinga, "abc-123", "BTBD") == false
    end

    test "treats different sources as distinct keys" do
      assert Dedup.check_and_mark(:benzinga, "abc-123", "BTBD") == true
      assert Dedup.check_and_mark(:sec, "abc-123", "BTBD") == true
      assert Dedup.check_and_mark(:pr_newswire, "abc-123", "BTBD") == true
    end

    test "treats different external_ids as distinct keys" do
      assert Dedup.check_and_mark(:benzinga, "abc-123", "BTBD") == true
      assert Dedup.check_and_mark(:benzinga, "abc-456", "BTBD") == true
    end

    test "treats different symbols as distinct keys" do
      assert Dedup.check_and_mark(:benzinga, "abc-123", "BTBD") == true
      assert Dedup.check_and_mark(:benzinga, "abc-123", "AAPL") == true
    end

    test "is atomic under concurrent access" do
      tasks =
        for _ <- 1..100 do
          Task.async(fn ->
            Dedup.check_and_mark(:benzinga, "race-test", "BTBD")
          end)
        end

      results = Task.await_many(tasks)
      assert Enum.count(results, & &1) == 1
      assert Enum.count(results, &(!&1)) == 99
    end
  end

  describe "seen?/3" do
    test "returns false before mark, true after mark" do
      refute Dedup.seen?(:benzinga, "abc-123", "BTBD")
      Dedup.check_and_mark(:benzinga, "abc-123", "BTBD")
      assert Dedup.seen?(:benzinga, "abc-123", "BTBD")
    end

    test "does not modify the table" do
      refute Dedup.seen?(:benzinga, "abc-123", "BTBD")
      refute Dedup.seen?(:benzinga, "abc-123", "BTBD")
      # Now mark it for real — should still be first sight
      assert Dedup.check_and_mark(:benzinga, "abc-123", "BTBD") == true
    end
  end

  describe "clear/0" do
    test "removes all entries" do
      Dedup.check_and_mark(:benzinga, "abc-123", "BTBD")
      Dedup.check_and_mark(:sec, "xyz-789", "AAPL")

      assert Dedup.seen?(:benzinga, "abc-123", "BTBD")
      assert Dedup.seen?(:sec, "xyz-789", "AAPL")

      :ok = Dedup.clear()

      refute Dedup.seen?(:benzinga, "abc-123", "BTBD")
      refute Dedup.seen?(:sec, "xyz-789", "AAPL")
    end
  end

  describe "cleanup" do
    @describetag :tmp_config

    setup do
      original_ttl = Application.get_env(:long_or_short, :news_dedup_ttl_seconds)
      Application.put_env(:long_or_short, :news_dedup_ttl_seconds, 1)

      on_exit(fn ->
        if original_ttl do
          Application.put_env(:long_or_short, :news_dedup_ttl_seconds, original_ttl)
        else
          Application.delete_env(:long_or_short, :news_dedup_ttl_seconds)
        end
      end)

      :ok
    end

    test "removes entries older than TTL when cleanup runs" do
      Dedup.check_and_mark(:benzinga, "old", "BTBD")
      assert Dedup.seen?(:benzinga, "old", "BTBD")

      Process.sleep(1_100)

      Dedup.check_and_mark(:benzinga, "new", "AAPL")

      send(Process.whereis(Dedup), :cleanup)

      _ = :sys.get_state(Dedup)

      refute Dedup.seen?(:benzinga, "old", "BTBD")
      assert Dedup.seen?(:benzinga, "new", "AAPL")
    end
  end
end
