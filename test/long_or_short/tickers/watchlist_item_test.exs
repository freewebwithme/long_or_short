defmodule LongOrShort.Tickers.WatchlistItemTest do
  use LongOrShort.DataCase, async: true

  import LongOrShort.{AccountsFixtures, TickersFixtures}

  alias LongOrShort.Tickers

  describe "add_to_watchlist/2" do
    test "creates a new watchlist item" do
      user = build_trader_user()
      ticker = build_ticker()

      assert {:ok, item} =
               Tickers.add_to_watchlist(
                 %{user_id: user.id, ticker_id: ticker.id},
                 authorize?: false
               )

      assert item.user_id == user.id
      assert item.ticker_id == ticker.id
      assert item.notify? == false
    end

    test "idempotent — second add returns existing row without error" do
      user = build_trader_user()
      ticker = build_ticker()

      {:ok, first} =
        Tickers.add_to_watchlist(%{user_id: user.id, ticker_id: ticker.id}, authorize?: false)

      {:ok, second} =
        Tickers.add_to_watchlist(%{user_id: user.id, ticker_id: ticker.id}, authorize?: false)

      assert first.id == second.id
    end

    test "same ticker can appear in different users' watchlists" do
      user_a = build_trader_user()
      user_b = build_trader_user()
      ticker = build_ticker()

      assert {:ok, _} =
               Tickers.add_to_watchlist(%{user_id: user_a.id, ticker_id: ticker.id},
                 authorize?: false
               )

      assert {:ok, _} =
               Tickers.add_to_watchlist(%{user_id: user_b.id, ticker_id: ticker.id},
                 authorize?: false
               )
    end

    test "same user can add multiple tickers" do
      user = build_trader_user()
      ticker_a = build_ticker()
      ticker_b = build_ticker()

      assert {:ok, _} =
               Tickers.add_to_watchlist(%{user_id: user.id, ticker_id: ticker_a.id},
                 authorize?: false
               )

      assert {:ok, _} =
               Tickers.add_to_watchlist(%{user_id: user.id, ticker_id: ticker_b.id},
                 authorize?: false
               )
    end
  end

  describe "remove_from_watchlist/2" do
    test "destroys the watchlist item by id" do
      item = build_watchlist_item()

      assert :ok = Tickers.remove_from_watchlist(item, authorize?: false)

      assert {:ok, []} = Tickers.list_watchlist(item.user_id, authorize?: false)
    end
  end

  describe "list_watchlist/2" do
    test "returns items for the given user ordered newest first" do
      user = build_trader_user()
      ticker_a = build_ticker()
      ticker_b = build_ticker()

      {:ok, first} =
        Tickers.add_to_watchlist(%{user_id: user.id, ticker_id: ticker_a.id}, authorize?: false)

      {:ok, second} =
        Tickers.add_to_watchlist(%{user_id: user.id, ticker_id: ticker_b.id}, authorize?: false)

      {:ok, items} = Tickers.list_watchlist(user.id, authorize?: false)

      ids = Enum.map(items, & &1.id)
      assert ids == [second.id, first.id]
    end

    test "pre-loads ticker association" do
      user = build_trader_user()
      ticker = build_ticker(%{symbol: "LISTTEST"})

      Tickers.add_to_watchlist(%{user_id: user.id, ticker_id: ticker.id}, authorize?: false)

      {:ok, [item]} = Tickers.list_watchlist(user.id, authorize?: false)

      assert %LongOrShort.Tickers.Ticker{symbol: "LISTTEST"} = item.ticker
    end

    test "returns empty list when user has no items" do
      user = build_trader_user()

      assert {:ok, []} = Tickers.list_watchlist(user.id, authorize?: false)
    end

    test "does not return another user's items" do
      user_a = build_trader_user()
      user_b = build_trader_user()
      ticker = build_ticker()

      Tickers.add_to_watchlist(%{user_id: user_b.id, ticker_id: ticker.id}, authorize?: false)

      assert {:ok, []} = Tickers.list_watchlist(user_a.id, authorize?: false)
    end
  end

  describe "User.watchlist_items (has_many)" do
    test "loads watchlist items when present" do
      user = build_trader_user()
      item = build_watchlist_item(%{user_id: user.id})

      {:ok, loaded} =
        Ash.get(LongOrShort.Accounts.User, user.id,
          load: [:watchlist_items],
          authorize?: false
        )

      assert Enum.any?(loaded.watchlist_items, &(&1.id == item.id))
    end

    test "loads empty list when user has no watchlist items" do
      user = build_trader_user()

      {:ok, loaded} =
        Ash.get(LongOrShort.Accounts.User, user.id,
          load: [:watchlist_items],
          authorize?: false
        )

      assert loaded.watchlist_items == []
    end
  end

  describe "policies" do
    test "system actor can add to watchlist" do
      user = build_trader_user()
      ticker = build_ticker()

      assert {:ok, _} =
               Tickers.add_to_watchlist(
                 %{user_id: user.id, ticker_id: ticker.id},
                 actor: LongOrShort.Accounts.SystemActor.new()
               )
    end

    test "admin can add to watchlist" do
      admin = build_admin_user()
      user = build_trader_user()
      ticker = build_ticker()

      assert {:ok, _} =
               Tickers.add_to_watchlist(%{user_id: user.id, ticker_id: ticker.id}, actor: admin)
    end

    test "trader can add to watchlist" do
      trader = build_trader_user()
      ticker = build_ticker()

      assert {:ok, _} =
               Tickers.add_to_watchlist(%{user_id: trader.id, ticker_id: ticker.id},
                 actor: trader
               )
    end

    test "trader can list watchlist" do
      trader = build_trader_user()

      assert {:ok, _} = Tickers.list_watchlist(trader.id, actor: trader)
    end

    test "trader can remove from watchlist" do
      trader = build_trader_user()
      item = build_watchlist_item(%{user_id: trader.id})

      assert :ok = Tickers.remove_from_watchlist(item, actor: trader)
    end

    test "unauthenticated actor cannot add to watchlist" do
      user = build_trader_user()
      ticker = build_ticker()

      assert {:error, %Ash.Error.Forbidden{}} =
               Tickers.add_to_watchlist(%{user_id: user.id, ticker_id: ticker.id}, actor: nil)
    end

    test "nil actor sees empty list (read policy filters rather than errors)" do
      user = build_trader_user()
      build_watchlist_item(%{user_id: user.id})

      assert {:ok, []} = Tickers.list_watchlist(user.id, actor: nil)
    end
  end
end
