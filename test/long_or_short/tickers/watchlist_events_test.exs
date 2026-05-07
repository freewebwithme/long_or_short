defmodule LongOrShort.Tickers.WatchlistEventsTest do
  use ExUnit.Case, async: false

  alias LongOrShort.Tickers.WatchlistEvents

  describe "broadcast_changed/1" do
    test "delivers to the per-user subscriber" do
      user_id = Ash.UUID.generate()
      :ok = WatchlistEvents.subscribe(user_id)

      WatchlistEvents.broadcast_changed(user_id)

      assert_receive {:watchlist_changed, ^user_id}
    end

    test "delivers to subscribers on the global watchlist:any topic" do
      :ok = WatchlistEvents.subscribe_any()

      user_id = Ash.UUID.generate()
      WatchlistEvents.broadcast_changed(user_id)

      assert_receive {:watchlist_changed, ^user_id}
    end

    test "fans out to per-user and global subscribers in a single broadcast" do
      user_id = Ash.UUID.generate()
      :ok = WatchlistEvents.subscribe(user_id)
      :ok = WatchlistEvents.subscribe_any()

      WatchlistEvents.broadcast_changed(user_id)

      # Two separate messages — one per topic — to the same process.
      assert_receive {:watchlist_changed, ^user_id}
      assert_receive {:watchlist_changed, ^user_id}
    end

    test "per-user subscriber only receives its own user's events" do
      user_a = Ash.UUID.generate()
      user_b = Ash.UUID.generate()
      :ok = WatchlistEvents.subscribe(user_a)

      WatchlistEvents.broadcast_changed(user_b)

      refute_receive {:watchlist_changed, ^user_b}, 100
    end
  end
end
