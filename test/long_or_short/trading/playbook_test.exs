defmodule LongOrShort.Trading.PlaybookTest do
  @moduledoc """
  Tests for `LongOrShort.Trading.Playbook` (LON-181, TW-1 of [[LON-180]]).

  Covers:
    * `:create_version` — first version, increment, active flip, cap
    * `:update_items` — in-place mutation, no version bump, id stability
    * `:read_active`, `:read_all_versions` — query semantics
    * `:destroy` — cascade to PlaybookCheckState via DB FK
    * Per-action policies — actor must own the row
  """

  use LongOrShort.DataCase, async: false

  import LongOrShort.AccountsFixtures
  import LongOrShort.TradingFixtures

  alias LongOrShort.Trading
  alias LongOrShort.Trading.Playbook

  # ── :create_version ─────────────────────────────────────────────

  describe "create_version/4 — first version in a chain" do
    test "creates with version: 1, active: true, items embedded" do
      user = build_trader_user()

      {:ok, pb} =
        Trading.create_playbook_version(
          user.id,
          :rules,
          "Daily rules",
          [%{text: "Daily max loss $160"}, %{text: "Stop loss 엄수"}],
          authorize?: false
        )

      assert pb.version == 1
      assert pb.active == true
      assert pb.user_id == user.id
      assert pb.kind == :rules
      assert pb.name == "Daily rules"
      assert length(pb.items) == 2
      # Each item gets a server-generated UUID
      assert Enum.all?(pb.items, &is_binary(&1.id))
      assert Enum.map(pb.items, & &1.text) == ["Daily max loss $160", "Stop loss 엄수"]
    end
  end

  describe "create_version/4 — subsequent versions" do
    test "increments :version and flips prior :active to false" do
      user = build_trader_user()

      v1 = build_playbook(%{user_id: user.id, items: [%{text: "v1 item"}]})
      assert v1.version == 1
      assert v1.active == true

      {:ok, v2} =
        Trading.create_playbook_version(user.id, :rules, "Daily rules",
          [%{text: "v2 item"}], authorize?: false)

      assert v2.version == 2
      assert v2.active == true

      # Reload v1 and verify it was deactivated
      {:ok, v1_after} = Trading.get_playbook(v1.id, authorize?: false)
      assert v1_after.active == false
    end

    test "different (kind, name) chains are independent" do
      user = build_trader_user()

      rules_v1 = build_playbook(%{user_id: user.id, kind: :rules, name: "Daily rules"})
      setup_v1 = build_playbook(%{user_id: user.id, kind: :setup, name: "Long setup"})

      # Both should be version 1 and active — separate chains
      assert rules_v1.version == 1
      assert setup_v1.version == 1
      assert rules_v1.active == true
      assert setup_v1.active == true

      # Bumping rules doesn't affect setup
      {:ok, _rules_v2} =
        Trading.create_playbook_version(user.id, :rules, "Daily rules",
          [%{text: "v2"}], authorize?: false)

      {:ok, setup_after} = Trading.get_playbook(setup_v1.id, authorize?: false)
      assert setup_after.active == true
    end
  end

  describe "create_version/4 — 3-version cap" do
    test "rejects the 4th version with a manual-delete message" do
      user = build_trader_user()

      Enum.each(1..3, fn i ->
        {:ok, _} =
          Trading.create_playbook_version(user.id, :rules, "Daily rules",
            [%{text: "v#{i} item"}], authorize?: false)
      end)

      result =
        Trading.create_playbook_version(user.id, :rules, "Daily rules",
          [%{text: "v4 item"}], authorize?: false)

      assert {:error, %{errors: errors}} = result
      assert Enum.any?(errors, fn e ->
               e.message =~ "3 versions already" and e.message =~ "/trading/edit"
             end)

      # Chain still has exactly 3 rows
      {:ok, all} =
        Trading.list_playbook_versions(user.id, :rules, "Daily rules", authorize?: false)

      assert length(all) == 3
    end

    test "cap is per (user, kind, name) — different chains aren't counted together" do
      user = build_trader_user()

      # Fill the rules chain to the cap
      Enum.each(1..3, fn i ->
        {:ok, _} =
          Trading.create_playbook_version(user.id, :rules, "Daily rules",
            [%{text: "rules v#{i}"}], authorize?: false)
      end)

      # Setup chain (different name) should still accept new versions
      {:ok, setup_v1} =
        Trading.create_playbook_version(user.id, :setup, "Long setup",
          [%{text: "setup v1"}], authorize?: false)

      assert setup_v1.version == 1
    end
  end

  # ── :update_items ───────────────────────────────────────────────

  describe "update_items/2 — typo-fix path" do
    test "mutates :items without bumping :version" do
      pb = build_playbook()
      original_version = pb.version

      new_items = [%{text: "Edited text"}, %{text: "Another item"}]

      {:ok, updated} =
        pb
        |> Ash.Changeset.for_update(:update_items, %{items: new_items}, authorize?: false)
        |> Ash.update()

      assert updated.id == pb.id
      assert updated.version == original_version
      assert updated.active == true
      assert Enum.map(updated.items, & &1.text) == ["Edited text", "Another item"]
    end

    test "preserves item ids when caller passes them through" do
      pb = build_playbook(%{items: [%{text: "Original"}]})
      original_item_id = pb.items |> List.first() |> Map.get(:id)

      # Caller passes the existing id back — TW-4 form UI's responsibility
      new_items = [
        %{id: original_item_id, text: "Edited text"},
        %{text: "Brand new item"}
      ]

      {:ok, updated} =
        pb
        |> Ash.Changeset.for_update(:update_items, %{items: new_items}, authorize?: false)
        |> Ash.update()

      [first, second] = updated.items
      assert first.id == original_item_id
      assert first.text == "Edited text"
      # New item got a freshly-generated UUID
      assert is_binary(second.id)
      assert second.id != original_item_id
    end
  end

  # ── :read_active / :read_all_versions ───────────────────────────

  describe "read_active/1" do
    test "returns only active rows for the user, sorted by [kind, name]" do
      user = build_trader_user()

      # Build a few chains, some with multiple versions (latest = active)
      build_playbook(%{user_id: user.id, kind: :rules, name: "Daily rules"})
      build_playbook(%{user_id: user.id, kind: :setup, name: "Long setup"})

      {:ok, _v2_setup} =
        Trading.create_playbook_version(user.id, :setup, "Long setup",
          [%{text: "setup v2"}], authorize?: false)

      build_playbook(%{user_id: user.id, kind: :setup, name: "Short setup"})

      {:ok, active} = Trading.list_active_playbooks(user.id, authorize?: false)

      assert length(active) == 3

      # All active
      assert Enum.all?(active, & &1.active)

      # Sort: kind asc, then name asc — :rules < :setup alphabetically
      names = Enum.map(active, & &1.name)
      assert names == ["Daily rules", "Long setup", "Short setup"]
    end

    test "does not include other users' playbooks" do
      mine = build_trader_user()
      other = build_trader_user()

      build_playbook(%{user_id: mine.id, name: "Mine"})
      build_playbook(%{user_id: other.id, name: "Theirs"})

      {:ok, active} = Trading.list_active_playbooks(mine.id, authorize?: false)

      assert length(active) == 1
      assert List.first(active).name == "Mine"
    end
  end

  describe "read_all_versions/3" do
    test "returns full chain newest-first" do
      user = build_trader_user()

      Enum.each(1..3, fn i ->
        {:ok, _} =
          Trading.create_playbook_version(user.id, :rules, "Daily rules",
            [%{text: "v#{i}"}], authorize?: false)
      end)

      {:ok, versions} =
        Trading.list_playbook_versions(user.id, :rules, "Daily rules", authorize?: false)

      versions_seq = Enum.map(versions, & &1.version)
      assert versions_seq == [3, 2, 1]
    end
  end

  # ── :destroy ────────────────────────────────────────────────────

  describe "destroy/1 — cascade behaviour" do
    test "deleting a playbook cascades to its PlaybookCheckState rows" do
      pb = build_playbook()
      cs = build_check_state(%{user_id: pb.user_id, playbook_id: pb.id})

      assert :ok = Ash.destroy!(pb, authorize?: false)

      # CheckState should be gone via the on_delete: :delete_all FK
      result =
        LongOrShort.Trading.PlaybookCheckState
        |> Ash.get(cs.id, authorize?: false)

      assert {:error, _} = result
    end
  end

  # ── Policies ────────────────────────────────────────────────────

  describe "policies" do
    test "user can only read their own playbooks" do
      mine = build_trader_user()
      other = build_trader_user()

      mine_pb = build_playbook(%{user_id: mine.id})
      _other_pb = build_playbook(%{user_id: other.id})

      # As `mine`, listing active should return only my playbook
      {:ok, active} = Trading.list_active_playbooks(mine.id, actor: mine)
      assert length(active) == 1
      assert List.first(active).id == mine_pb.id
    end

    # NOTE: Ash 3.x doesn't support `expr(user_id == ^actor(:id))` as a
    # `:create` policy — at policy-eval time the row doesn't exist yet, so
    # the filter can't run. The mirror pattern in `TickerBriefing` (LON-172)
    # has the same gap and is enforced at the UI layer (LiveView sets
    # `user_id` from `socket.assigns.current_user.id`, never from user input).
    # If a future API surface exposes this resource directly, swap the
    # create policy to a custom `Ash.Policy.SimpleCheck` module.

    test "system actor bypass: can read any user's playbooks" do
      other = build_trader_user()
      _pb = build_playbook(%{user_id: other.id})

      system = LongOrShort.Accounts.SystemActor.new("test")

      {:ok, active} = Trading.list_active_playbooks(other.id, actor: system)
      assert length(active) == 1
    end
  end

  # ── Item embed constraints ──────────────────────────────────────

  describe "PlaybookItem text validation" do
    test "rejects items with empty text (min_length: 1)" do
      user = build_trader_user()

      result =
        Trading.create_playbook_version(user.id, :rules, "Bad",
          [%{text: ""}], authorize?: false)

      assert {:error, _} = result
    end

    test "rejects items with text > 280 chars (max_length)" do
      user = build_trader_user()
      too_long = String.duplicate("x", 281)

      result =
        Trading.create_playbook_version(user.id, :rules, "Bad",
          [%{text: too_long}], authorize?: false)

      assert {:error, _} = result
    end

    test "accepts items at the exact 280-char boundary" do
      user = build_trader_user()
      at_max = String.duplicate("x", 280)

      assert {:ok, pb} =
               Trading.create_playbook_version(user.id, :rules, "Edge",
                 [%{text: at_max}], authorize?: false)

      assert pb.items |> List.first() |> Map.get(:text) |> String.length() == 280
    end
  end

  # ── Implicit verification: items have stable UUIDs ──────────────

  describe "items embed identity" do
    test "items carry server-generated UUIDs that persist on reload" do
      pb = build_playbook(%{items: [%{text: "First"}, %{text: "Second"}]})

      original_ids = Enum.map(pb.items, & &1.id)
      assert Enum.all?(original_ids, &is_binary/1)
      assert length(Enum.uniq(original_ids)) == 2

      # Reload the row and verify the same ids come back
      {:ok, %Playbook{items: reloaded_items}} = Trading.get_playbook(pb.id, authorize?: false)
      reloaded_ids = Enum.map(reloaded_items, & &1.id)

      assert reloaded_ids == original_ids
    end
  end
end
