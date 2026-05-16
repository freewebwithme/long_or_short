defmodule LongOrShort.Trading.Note do
  @moduledoc """
  Daily trader journal entry (LON-182, TW-2 of [[LON-180]]).

  One row per `(user_id, trading_date)` where `trading_date` is ET
  wall-clock. The trader writes freeform Markdown into `:body`
  throughout the session and clicks Save to persist. Next ET day
  starts fresh; prior days are read-only via the `/trading` Notes
  history.

  ## Why daily-journal instead of stream-of-notes

  Original LON-182 spec was a stream model (one row per Save, with
  `:ticker_id` + `:related_briefing_id` per note). 2026-05-16 user
  pivot to daily-journal because:

    * Retrospection (POST-1, [[LON-176]]) looks up "what did I write
      on 2026-05-13?" — single-row lookup is cleaner than aggregating
      N timestamped rows.
    * Ticker references inline in body (`$NVDA went 234 → 240`) are
      enough; structured `ticker_id` per note was over-engineering for
      a solo-user tool.
    * Save button gives the trader explicit control vs. auto-save
      surprises.

  Freeform Markdown body keeps the paper-replacement feel that
  `Trading.Playbook` deliberately gave up (Playbook items are
  structured for check-state binding; notes have no such constraint).

  ## ET trading_date

  Computed server-side from `LongOrShort.Research.BriefingFreshness.et_now/0`
  at `:upsert_for_today` time. Mirrors `PlaybookCheckState`'s pattern
  exactly — both surfaces need the same "what day is it in NY?"
  answer, and the helper is already proven.
  """

  use Ash.Resource,
    otp_app: :long_or_short,
    domain: LongOrShort.Trading,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  require Ash.Query

  alias LongOrShort.Research.BriefingFreshness

  postgres do
    table "trading_notes"
    repo LongOrShort.Repo

    references do
      reference :user, on_delete: :delete
    end
  end

  identities do
    identity :unique_note_per_day, [:user_id, :trading_date]
  end

  attributes do
    uuid_v7_primary_key :id
    create_timestamp :inserted_at
    update_timestamp :updated_at

    attribute :trading_date, :date do
      allow_nil? false
      public? true

      description """
      ET wall-clock date the note belongs to. Computed by
      `:upsert_for_today` — callers never pass it. Notes written at
      23:59 ET 2026-05-16 belong to that day's row even if the
      server clock is past UTC midnight.
      """
    end

    attribute :body, :string do
      allow_nil? false
      public? true
      default ""

      description """
      Markdown body, freeform. The Save button (TW-3) calls
      `:update_body` to populate it. Soft cap policy left to the
      UI — DB accepts any length Postgres `:text` can hold.
      """
    end
  end

  relationships do
    belongs_to :user, LongOrShort.Accounts.User do
      allow_nil? false
      attribute_writable? true
      public? true
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:user_id, :trading_date, :body]
    end

    update :update do
      primary? true
      accept [:body]
    end

    # Idempotent get-or-create for today's row. ET trading_date is
    # server-set; on hit, returns the existing row with body
    # preserved (callers don't accidentally blank the trader's notes
    # by re-mounting the LiveView).
    # Save today's note — upsert by `(user_id, trading_date)`. Both
    # create (first save of the day) and update (subsequent saves)
    # go through this single entry point. `:trading_date` is
    # server-computed; `:body` is caller-provided. LiveView holds
    # the draft body in socket assigns and persists only on Save.
    #
    # Design note: an earlier `:upsert_for_today` that took only
    # `:user_id` and seeded an empty row on LiveView mount ran into
    # Ash 3.x's required-field check, which fires before changes
    # apply defaults. There's no clean pre-validation hook for the
    # "set empty string default" case. Routing the body through the
    # save action sidesteps the issue and is cleaner anyway — no
    # half-empty rows materialize for users who open `/trading`
    # and never write anything.
    create :save_for_today do
      accept [:user_id, :body]
      upsert? true
      upsert_identity :unique_note_per_day
      upsert_fields [:body]

      change before_action(fn changeset, _ctx ->
               today = BriefingFreshness.et_now() |> DateTime.to_date()
               Ash.Changeset.force_change_attribute(changeset, :trading_date, today)
             end)
    end

    # Today's note, or nil. The LiveView mount path uses this to
    # decide between "render existing journal" and "render empty
    # textarea" — pairs with `:upsert_for_today` for the click-Save
    # flow.
    read :read_today do
      argument :user_id, :uuid_v7, allow_nil?: false

      prepare fn query, _ctx ->
        today = BriefingFreshness.et_now() |> DateTime.to_date()
        user_id = Ash.Query.get_argument(query, :user_id)
        Ash.Query.filter(query, user_id == ^user_id and trading_date == ^today)
      end
    end

    # Historical date lookup. Same date semantics as `:read_today`
    # but caller-provided — used by Note history modal (TW-3) and
    # retrospection (LON-176).
    read :get_for_date do
      argument :user_id, :uuid_v7, allow_nil?: false
      argument :trading_date, :date, allow_nil?: false

      filter expr(
               user_id == ^arg(:user_id) and
                 trading_date == ^arg(:trading_date)
             )
    end

    # Inclusive date range, newest-first. Powers the history view.
    read :by_date_range do
      argument :user_id, :uuid_v7, allow_nil?: false
      argument :from_date, :date, allow_nil?: false
      argument :to_date, :date, allow_nil?: false

      filter expr(
               user_id == ^arg(:user_id) and
                 trading_date >= ^arg(:from_date) and
                 trading_date <= ^arg(:to_date)
             )

      prepare build(sort: [trading_date: :desc])
    end
  end

  policies do
    bypass actor_attribute_equals(:system?, true) do
      authorize_if always()
    end

    bypass actor_attribute_equals(:role, :admin) do
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if expr(user_id == ^actor(:id))
    end

    policy action_type(:create) do
      authorize_if expr(user_id == ^actor(:id))
    end

    policy action_type(:update) do
      authorize_if expr(user_id == ^actor(:id))
    end

    policy action_type(:destroy) do
      authorize_if expr(user_id == ^actor(:id))
    end
  end
end
