defmodule LongOrShort.Trading.PlaybookCheckStateTest do
  @moduledoc """
  Tests for `LongOrShort.Trading.PlaybookCheckState` (LON-181, TW-1
  of [[LON-180]]).

  Covers:
    * `:upsert_for_today` — idempotent get-or-create with server-set
      ET trading_date
    * `:toggle_item` — map mutation (check → uncheck → check)
    * `:read_for_date` / `:read_today` — date-scoped reads
    * Policies — cross-user isolation
  """

  use LongOrShort.DataCase, async: false

  import LongOrShort.AccountsFixtures
  import LongOrShort.TradingFixtures

  alias LongOrShort.Research.BriefingFreshness
  alias LongOrShort.Trading
  alias LongOrShort.Trading.PlaybookCheckState

  # ── :upsert_for_today ───────────────────────────────────────────

  describe "upsert_check_state_for_today/2" do
    test "creates a new row with today's ET trading_date and empty checked_items" do
      pb = build_playbook()
      today_et = BriefingFreshness.et_now() |> DateTime.to_date()

      {:ok, cs} =
        Trading.upsert_check_state_for_today(pb.user_id, pb.id, authorize?: false)

      assert cs.user_id == pb.user_id
      assert cs.playbook_id == pb.id
      assert cs.trading_date == today_et
      assert cs.checked_items == %{}
    end

    test "is idempotent — second call returns the same row" do
      pb = build_playbook()

      {:ok, first} =
        Trading.upsert_check_state_for_today(pb.user_id, pb.id, authorize?: false)

      {:ok, second} =
        Trading.upsert_check_state_for_today(pb.user_id, pb.id, authorize?: false)

      assert first.id == second.id
    end

    test "preserves checked_items on idempotent upsert (no reset to %{})" do
      pb = build_playbook(%{items: [%{text: "First"}]})
      item_id = pb.items |> List.first() |> Map.get(:id)

      cs = build_check_state(%{user_id: pb.user_id, playbook_id: pb.id})

      # Toggle to populate checked_items
      {:ok, cs_with_check} =
        Trading.toggle_playbook_item(cs, item_id, authorize?: false)

      refute cs_with_check.checked_items == %{}

      # Upsert again — must NOT wipe checked_items
      {:ok, upserted_again} =
        Trading.upsert_check_state_for_today(pb.user_id, pb.id, authorize?: false)

      assert upserted_again.id == cs.id
      assert upserted_again.checked_items == cs_with_check.checked_items
    end
  end

  # ── :toggle_item ────────────────────────────────────────────────

  describe "toggle_playbook_item/2" do
    test "adds the item_id with an ISO-8601 UTC timestamp on first toggle" do
      pb = build_playbook(%{items: [%{text: "Item A"}]})
      item_id = pb.items |> List.first() |> Map.get(:id)
      cs = build_check_state(%{user_id: pb.user_id, playbook_id: pb.id})

      {:ok, after_check} =
        Trading.toggle_playbook_item(cs, item_id, authorize?: false)

      assert Map.has_key?(after_check.checked_items, item_id)

      ts = after_check.checked_items[item_id]
      assert {:ok, _dt, 0} = DateTime.from_iso8601(ts)
    end

    test "removes the item_id on second toggle (uncheck)" do
      pb = build_playbook(%{items: [%{text: "Item A"}]})
      item_id = pb.items |> List.first() |> Map.get(:id)
      cs = build_check_state(%{user_id: pb.user_id, playbook_id: pb.id})

      {:ok, checked} = Trading.toggle_playbook_item(cs, item_id, authorize?: false)
      {:ok, unchecked} = Trading.toggle_playbook_item(checked, item_id, authorize?: false)

      assert unchecked.checked_items == %{}
    end

    test "toggling different items accumulates entries" do
      pb =
        build_playbook(%{
          items: [%{text: "A"}, %{text: "B"}, %{text: "C"}]
        })

      [a, b, c] = pb.items
      cs = build_check_state(%{user_id: pb.user_id, playbook_id: pb.id})

      {:ok, cs1} = Trading.toggle_playbook_item(cs, a.id, authorize?: false)
      {:ok, cs2} = Trading.toggle_playbook_item(cs1, b.id, authorize?: false)
      {:ok, cs3} = Trading.toggle_playbook_item(cs2, c.id, authorize?: false)

      assert Map.keys(cs3.checked_items) |> Enum.sort() ==
               Enum.sort([a.id, b.id, c.id])
    end

    test "unchecking one item leaves siblings intact" do
      pb = build_playbook(%{items: [%{text: "A"}, %{text: "B"}]})
      [a, b] = pb.items
      cs = build_check_state(%{user_id: pb.user_id, playbook_id: pb.id})

      {:ok, cs1} = Trading.toggle_playbook_item(cs, a.id, authorize?: false)
      {:ok, cs2} = Trading.toggle_playbook_item(cs1, b.id, authorize?: false)

      # Uncheck only A
      {:ok, cs3} = Trading.toggle_playbook_item(cs2, a.id, authorize?: false)

      refute Map.has_key?(cs3.checked_items, a.id)
      assert Map.has_key?(cs3.checked_items, b.id)
    end
  end

  # ── :read_today ─────────────────────────────────────────────────

  describe "list_check_states_for_today/1" do
    test "returns the user's check states for today, sorted by playbook_id" do
      user = build_trader_user()
      pb1 = build_playbook(%{user_id: user.id, kind: :rules, name: "Daily rules"})
      pb2 = build_playbook(%{user_id: user.id, kind: :setup, name: "Long setup"})

      _cs1 = build_check_state(%{user_id: user.id, playbook_id: pb1.id})
      _cs2 = build_check_state(%{user_id: user.id, playbook_id: pb2.id})

      {:ok, list} = Trading.list_check_states_for_today(user.id, authorize?: false)

      assert length(list) == 2
      assert Enum.all?(list, &(&1.user_id == user.id))

      today_et = BriefingFreshness.et_now() |> DateTime.to_date()
      assert Enum.all?(list, &(&1.trading_date == today_et))
    end

    test "does not include other users' check states" do
      mine = build_trader_user()
      other = build_trader_user()

      mine_pb = build_playbook(%{user_id: mine.id})
      other_pb = build_playbook(%{user_id: other.id})

      _mine_cs = build_check_state(%{user_id: mine.id, playbook_id: mine_pb.id})
      _other_cs = build_check_state(%{user_id: other.id, playbook_id: other_pb.id})

      {:ok, list} = Trading.list_check_states_for_today(mine.id, authorize?: false)

      assert length(list) == 1
      assert List.first(list).user_id == mine.id
    end

    test "excludes rows for past dates" do
      user = build_trader_user()
      pb = build_playbook(%{user_id: user.id})

      yesterday = Date.add(Date.utc_today(), -1)

      # Bypass :upsert_for_today (which forces today's date) and create directly
      {:ok, _old_cs} =
        PlaybookCheckState
        |> Ash.Changeset.for_create(
          :create,
          %{
            user_id: user.id,
            playbook_id: pb.id,
            trading_date: yesterday,
            checked_items: %{}
          },
          authorize?: false
        )
        |> Ash.create()

      # Also create today's row
      _today_cs = build_check_state(%{user_id: user.id, playbook_id: pb.id})

      {:ok, today_list} = Trading.list_check_states_for_today(user.id, authorize?: false)

      assert length(today_list) == 1
      today_et = BriefingFreshness.et_now() |> DateTime.to_date()
      assert List.first(today_list).trading_date == today_et
    end
  end

  # ── :read_for_date ──────────────────────────────────────────────

  describe "list_check_states_for_date/2" do
    test "returns rows for the requested date only" do
      user = build_trader_user()
      pb = build_playbook(%{user_id: user.id})

      target = ~D[2026-04-15]

      {:ok, target_row} =
        PlaybookCheckState
        |> Ash.Changeset.for_create(
          :create,
          %{
            user_id: user.id,
            playbook_id: pb.id,
            trading_date: target,
            checked_items: %{}
          },
          authorize?: false
        )
        |> Ash.create()

      # Add a row for a different date that must not show up
      {:ok, _other_row} =
        PlaybookCheckState
        |> Ash.Changeset.for_create(
          :create,
          %{
            user_id: user.id,
            playbook_id: pb.id,
            trading_date: ~D[2026-04-16],
            checked_items: %{}
          },
          authorize?: false
        )
        |> Ash.create()

      {:ok, list} = Trading.list_check_states_for_date(user.id, target, authorize?: false)

      assert length(list) == 1
      assert List.first(list).id == target_row.id
    end
  end

  # ── Policies ────────────────────────────────────────────────────

  describe "policies" do
    test "user can only read their own check states" do
      mine = build_trader_user()
      other = build_trader_user()

      mine_pb = build_playbook(%{user_id: mine.id})
      other_pb = build_playbook(%{user_id: other.id})

      _mine_cs = build_check_state(%{user_id: mine.id, playbook_id: mine_pb.id})
      _other_cs = build_check_state(%{user_id: other.id, playbook_id: other_pb.id})

      {:ok, list} = Trading.list_check_states_for_today(mine.id, actor: mine)

      assert length(list) == 1
      assert List.first(list).user_id == mine.id
    end

    test "system actor bypass: can read any user's check states" do
      other = build_trader_user()
      other_pb = build_playbook(%{user_id: other.id})
      _cs = build_check_state(%{user_id: other.id, playbook_id: other_pb.id})

      system = LongOrShort.Accounts.SystemActor.new("test")

      {:ok, list} = Trading.list_check_states_for_today(other.id, actor: system)
      assert length(list) == 1
    end
  end
end
