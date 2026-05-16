defmodule LongOrShort.Trading.NoteTest do
  @moduledoc """
  Tests for `LongOrShort.Trading.Note` (LON-182, TW-2 of [[LON-180]]).

  Covers:
    * `:save_for_today` — upsert by `(user_id, trading_date)`; same
      action for first save and subsequent edits
    * `:read_today` — ET-today scoped read, nil on miss
    * `:get_for_date` — historical date lookup
    * `:by_date_range` — date range, newest-first
    * Policies — cross-user isolation
  """

  use LongOrShort.DataCase, async: false

  import LongOrShort.AccountsFixtures
  import LongOrShort.TradingFixtures

  alias LongOrShort.Research.BriefingFreshness
  alias LongOrShort.Trading
  alias LongOrShort.Trading.Note

  # ── :save_for_today ─────────────────────────────────────────────

  describe "save_note_for_today/2" do
    test "creates a new row with today's ET trading_date and the provided body" do
      user = build_trader_user()
      today_et = BriefingFreshness.et_now() |> DateTime.to_date()

      {:ok, note} =
        Trading.save_note_for_today(user.id, "morning watch", authorize?: false)

      assert note.user_id == user.id
      assert note.trading_date == today_et
      assert note.body == "morning watch"
    end

    test "second call for the same day updates the same row" do
      user = build_trader_user()

      {:ok, first} = Trading.save_note_for_today(user.id, "v1", authorize?: false)
      {:ok, second} = Trading.save_note_for_today(user.id, "v2", authorize?: false)

      assert first.id == second.id
      assert second.body == "v2"
    end

    test "bumps :updated_at on edit but preserves trading_date" do
      {:ok, first} = Trading.save_note_for_today(build_trader_user().id, "v1", authorize?: false)
      original_date = first.trading_date

      {:ok, second} = Trading.save_note_for_today(first.user_id, "v2", authorize?: false)

      assert second.id == first.id
      assert second.trading_date == original_date
      assert DateTime.compare(second.updated_at, first.updated_at) in [:gt, :eq]
    end
  end

  # ── :read_today ─────────────────────────────────────────────────

  describe "get_note_for_today/1" do
    test "returns nil when the user has no note for today" do
      user = build_trader_user()

      assert {:ok, nil} = Trading.get_note_for_today(user.id, authorize?: false)
    end

    test "returns the user's today note when one exists" do
      note = build_note(%{body: "watching premarket"})

      {:ok, fetched} = Trading.get_note_for_today(note.user_id, authorize?: false)
      assert fetched.id == note.id
      assert fetched.body == "watching premarket"
    end

    test "does not return another user's note" do
      mine = build_trader_user()
      other = build_trader_user()

      _other_note = build_note(%{user_id: other.id, body: "their note"})

      assert {:ok, nil} = Trading.get_note_for_today(mine.id, authorize?: false)
    end
  end

  # ── :get_for_date ───────────────────────────────────────────────

  describe "get_note_for_date/2" do
    test "returns the row for the requested historical date" do
      user = build_trader_user()
      target = ~D[2026-04-15]

      {:ok, historical} =
        Note
        |> Ash.Changeset.for_create(
          :create,
          %{user_id: user.id, trading_date: target, body: "April notes"},
          authorize?: false
        )
        |> Ash.create()

      {:ok, fetched} = Trading.get_note_for_date(user.id, target, authorize?: false)
      assert fetched.id == historical.id
      assert fetched.body == "April notes"
    end

    test "returns nil when no row exists for the date" do
      user = build_trader_user()

      assert {:ok, nil} =
               Trading.get_note_for_date(user.id, ~D[2026-04-15], authorize?: false)
    end
  end

  # ── :by_date_range ──────────────────────────────────────────────

  describe "list_notes_by_date_range/3" do
    test "returns rows in the inclusive range, newest first" do
      user = build_trader_user()

      dates = [~D[2026-04-13], ~D[2026-04-14], ~D[2026-04-15], ~D[2026-04-16]]

      Enum.each(dates, fn d ->
        {:ok, _} =
          Note
          |> Ash.Changeset.for_create(
            :create,
            %{user_id: user.id, trading_date: d, body: "note for #{Date.to_string(d)}"},
            authorize?: false
          )
          |> Ash.create()
      end)

      # Inclusive range 04-14 .. 04-16 should return 3 rows
      {:ok, list} =
        Trading.list_notes_by_date_range(
          user.id,
          ~D[2026-04-14],
          ~D[2026-04-16],
          authorize?: false
        )

      assert length(list) == 3

      # Newest first
      assert Enum.map(list, & &1.trading_date) == [
               ~D[2026-04-16],
               ~D[2026-04-15],
               ~D[2026-04-14]
             ]
    end

    test "excludes another user's notes within the same range" do
      mine = build_trader_user()
      other = build_trader_user()

      Enum.each([mine, other], fn user ->
        {:ok, _} =
          Note
          |> Ash.Changeset.for_create(
            :create,
            %{user_id: user.id, trading_date: ~D[2026-04-15], body: "April 15"},
            authorize?: false
          )
          |> Ash.create()
      end)

      {:ok, list} =
        Trading.list_notes_by_date_range(
          mine.id,
          ~D[2026-04-15],
          ~D[2026-04-15],
          authorize?: false
        )

      assert length(list) == 1
      assert List.first(list).user_id == mine.id
    end
  end

  # ── Policies ────────────────────────────────────────────────────

  describe "policies" do
    test "user can only read their own notes" do
      mine = build_trader_user()
      other = build_trader_user()

      _mine_note = build_note(%{user_id: mine.id, body: "mine"})
      _other_note = build_note(%{user_id: other.id, body: "theirs"})

      # As `mine`, listing today should return only my note
      today_et = BriefingFreshness.et_now() |> DateTime.to_date()

      {:ok, list} = Trading.list_notes_by_date_range(mine.id, today_et, today_et, actor: mine)

      assert length(list) == 1
      assert List.first(list).user_id == mine.id
    end

    test "system actor bypass: can read any user's notes" do
      other = build_trader_user()
      _note = build_note(%{user_id: other.id, body: "theirs"})

      system = LongOrShort.Accounts.SystemActor.new("test")
      today_et = BriefingFreshness.et_now() |> DateTime.to_date()

      {:ok, list} = Trading.list_notes_by_date_range(other.id, today_et, today_et, actor: system)

      assert length(list) == 1
    end
  end
end
