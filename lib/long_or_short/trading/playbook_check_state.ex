defmodule LongOrShort.Trading.PlaybookCheckState do
  @moduledoc """
  Today's checked-items map for a single playbook (LON-181, TW-1 of
  [[LON-180]]).

  One row per `(user_id, playbook_id, trading_date)` where
  `trading_date` is ET wall-clock (matches the trader's mental model
  — Asia trader on US markets shouldn't see UTC date drift mid-session).
  The row's `:checked_items` map persists which markdown todo items
  were checked at what time. Retrospection consumers
  ([[LON-176]] POST-1) read past dates to ask
  "was rule #3 checked before this trade?".

  ## `:checked_items` shape

      %{
        "01abc-def-..." => "2026-05-16T13:24:05.812Z",
        "01xyz-uvw-..." => "2026-05-16T13:24:12.345Z"
      }

  Keys are `LongOrShort.Trading.PlaybookItem.id` UUIDs — stable
  through reorders and text edits because the parent Playbook's
  `:items` is a structured embed, not parsed markdown. An earlier
  draft used `"<index>:<hash>"` composite keys to survive edits to
  a freeform markdown body; switching items to an embedded resource
  made that unnecessary. Values are ISO-8601 UTC timestamps (when
  the user clicked the check).

  Orphan keys (item deleted from the parent playbook) sit silently
  in the map until next `:toggle_item` write. Render code skips
  keys that don't match any current item id.

  ## Toggle semantics

  `:toggle_item` is the only mutation path for `:checked_items`. It
  reads the current map, removes the key if present (uncheck), or
  adds it with `DateTime.utc_now()` (check). The map is rewritten
  whole — not a partial JSON patch.

  Concurrency note: two near-simultaneous toggles on the same row
  could read stale state and conflict on write. Acceptable for TW-1;
  hardening (row-level lock or `phx-disable-with` debounce) is
  deferred until TW-3 surfaces real usage patterns.

  ## ET trading_date

  Computed from `LongOrShort.Research.BriefingFreshness.et_now/0` at
  `:upsert_for_today` time. The dependency on a `Research`-domain
  helper is intentional — both surfaces (Scout cache bucketing,
  Trading Workspace daily roll-over) need the same "what day is it
  in New York?" answer. Extract to a neutral `MarketCalendar`
  module if a third consumer appears.
  """

  use Ash.Resource,
    otp_app: :long_or_short,
    domain: LongOrShort.Trading,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  require Ash.Query

  alias LongOrShort.Research.BriefingFreshness

  postgres do
    table "trading_playbook_check_states"
    repo LongOrShort.Repo

    references do
      reference :user, on_delete: :delete
      reference :playbook, on_delete: :delete
    end
  end

  identities do
    identity :unique_check_state_per_day, [:user_id, :playbook_id, :trading_date]
  end

  attributes do
    uuid_v7_primary_key :id
    create_timestamp :inserted_at
    update_timestamp :updated_at

    attribute :trading_date, :date do
      allow_nil? false
      public? true

      description """
      ET wall-clock date the check state belongs to. Computed by
      `:upsert_for_today` — callers never pass it. A trade taken at
      23:59 ET 2026-05-16 belongs to that day's row even if the
      server clock is past UTC midnight.
      """
    end

    attribute :checked_items, :map do
      allow_nil? false
      public? true
      default %{}

      description """
      `%{item_id_string => iso8601_utc_string}`. See moduledoc for
      shape. Mutated only via `:toggle_item`.
      """
    end
  end

  relationships do
    belongs_to :user, LongOrShort.Accounts.User do
      allow_nil? false
      attribute_writable? true
      public? true
    end

    belongs_to :playbook, LongOrShort.Trading.Playbook do
      allow_nil? false
      attribute_writable? true
      public? true
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:user_id, :playbook_id, :trading_date, :checked_items]
    end

    update :update do
      primary? true
      accept [:checked_items]
    end

    # Idempotent get-or-create for today's row. Trading date is
    # computed server-side from ET wall-clock, so callers can't
    # accidentally land in the wrong day's bucket by passing
    # `Date.utc_today()`.
    create :upsert_for_today do
      accept [:user_id, :playbook_id]
      upsert? true
      upsert_identity :unique_check_state_per_day

      # On upsert hit, don't touch checked_items — preserve whatever
      # the trader has already toggled today.
      upsert_fields []

      change before_action(fn changeset, _ctx ->
               today = BriefingFreshness.et_now() |> DateTime.to_date()
               Ash.Changeset.force_change_attribute(changeset, :trading_date, today)
             end)
    end

    # Toggle a single markdown todo by item_id. Idempotent at the
    # value level: same `:item_id` toggled twice returns the map to
    # its prior state (minus the timestamp resolution difference).
    #
    # `require_atomic? false` because the change reads `data.checked_items`
    # — there's no SQL-side equivalent to "remove key if present, insert
    # if absent" on a jsonb map without round-tripping through Elixir.
    update :toggle_item do
      argument :item_id, :string, allow_nil?: false
      require_atomic? false

      change before_action(fn changeset, _ctx ->
               current = changeset.data.checked_items || %{}
               item_id = Ash.Changeset.get_argument(changeset, :item_id)

               next =
                 case Map.fetch(current, item_id) do
                   {:ok, _} ->
                     Map.delete(current, item_id)

                   :error ->
                     Map.put(current, item_id, DateTime.utc_now() |> DateTime.to_iso8601())
                 end

               Ash.Changeset.force_change_attribute(changeset, :checked_items, next)
             end)
    end

    # All check states for a specific historical date. Retrospection
    # consumers (LON-176) join this with trade records to detect rule
    # violations. Ordered by playbook to keep retrospection views
    # stable across runs.
    read :read_for_date do
      argument :user_id, :uuid_v7, allow_nil?: false
      argument :trading_date, :date, allow_nil?: false

      filter expr(
               user_id == ^arg(:user_id) and
                 trading_date == ^arg(:trading_date)
             )

      prepare build(sort: [playbook_id: :asc])
    end

    # Today's check states across all the user's playbooks. The
    # /trading LiveView (TW-3) loads this once on mount and updates
    # locally as the user toggles. Reads `et_now()` server-side so
    # the "today" definition is consistent with `:upsert_for_today`.
    #
    # `^arg/1` is a DSL-time macro and doesn't work inside a runtime
    # `prepare fn`; fetch the arg explicitly and pin its value.
    read :read_today do
      argument :user_id, :uuid_v7, allow_nil?: false

      prepare fn query, _ctx ->
        today = BriefingFreshness.et_now() |> DateTime.to_date()
        user_id = Ash.Query.get_argument(query, :user_id)
        Ash.Query.filter(query, user_id == ^user_id and trading_date == ^today)
      end

      prepare build(sort: [playbook_id: :asc])
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
