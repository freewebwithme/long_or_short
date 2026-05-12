defmodule LongOrShort.Tickers.WatchlistItemTest do
  use LongOrShort.DataCase, async: true
  use Oban.Testing, repo: LongOrShort.Repo

  import LongOrShort.{AccountsFixtures, TickersFixtures}

  alias LongOrShort.Filings.Workers.FilingAnalysisBackfillWorker
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

  describe "filing analysis backfill enqueue (LON-115)" do
    test "enqueues a FilingAnalysisBackfillWorker job after :add succeeds" do
      user = build_trader_user()
      ticker = build_ticker()

      {:ok, _item} =
        Tickers.add_to_watchlist(%{user_id: user.id, ticker_id: ticker.id}, authorize?: false)

      assert_enqueued(
        worker: FilingAnalysisBackfillWorker,
        args: %{"ticker_id" => ticker.id, "lookback_days" => 90}
      )
    end

    test "duplicate adds for the same ticker collapse to a single job (unique constraint)" do
      user_a = build_trader_user()
      user_b = build_trader_user()
      ticker = build_ticker()

      Tickers.add_to_watchlist(%{user_id: user_a.id, ticker_id: ticker.id}, authorize?: false)
      Tickers.add_to_watchlist(%{user_id: user_b.id, ticker_id: ticker.id}, authorize?: false)

      jobs =
        all_enqueued(worker: FilingAnalysisBackfillWorker)
        |> Enum.filter(&(&1.args["ticker_id"] == ticker.id))

      assert length(jobs) == 1
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

  # LON-138 regression tests — ownership scoping.
  describe "policies — ownership scoping (LON-138)" do
    test "trader A cannot destroy trader B's watchlist item" do
      trader_a = build_trader_user()
      trader_b = build_trader_user()
      item = build_watchlist_item(%{user_id: trader_b.id})

      assert {:error, %Ash.Error.Forbidden{}} =
               Tickers.remove_from_watchlist(item, actor: trader_a)

      # The item still exists.
      assert {:ok, [_]} = Tickers.list_watchlist(trader_b.id, actor: trader_b)
    end

    test "admin can destroy any trader's watchlist item" do
      admin = build_admin_user()
      trader = build_trader_user()
      item = build_watchlist_item(%{user_id: trader.id})

      assert :ok = Tickers.remove_from_watchlist(item, actor: admin)
      assert {:ok, []} = Tickers.list_watchlist(trader.id, authorize?: false)
    end

    test "trader cannot add to another user's watchlist (validation error)" do
      trader_a = build_trader_user()
      trader_b = build_trader_user()
      ticker = build_ticker()

      assert {:error, %Ash.Error.Invalid{}} =
               Tickers.add_to_watchlist(
                 %{user_id: trader_b.id, ticker_id: ticker.id},
                 actor: trader_a
               )

      # No row was created for trader_b.
      assert {:ok, []} = Tickers.list_watchlist(trader_b.id, authorize?: false)
    end

    test "trader A passing another user's id to list_watchlist sees empty list" do
      trader_a = build_trader_user()
      trader_b = build_trader_user()
      build_watchlist_item(%{user_id: trader_b.id})

      # Filter-style read policy: mismatched argument yields empty results,
      # not Forbidden. Trader A learns nothing about Trader B's watchlist.
      assert {:ok, []} = Tickers.list_watchlist(trader_b.id, actor: trader_a)
    end
  end
end
