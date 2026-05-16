defmodule LongOrShort.Trading.Playbook do
  @moduledoc """
  Versioned trader playbook — rules or setup checklist (LON-181, TW-1
  of [[LON-180]]).

  Each `(user_id, kind, name)` triple identifies a logical playbook
  (e.g. `(alice, :rules, "Daily rules")`), and the `:version` column
  builds an immutable history chain for that triple. New versions are
  created via `:create_version`; the latest is marked `active: true`
  and prior versions flipped to `active: false`.

  ## Structured items, not freeform Markdown

  The body is a list of embedded `LongOrShort.Trading.PlaybookItem`
  records (UUID + text), serialized into the `:items` jsonb column.
  An earlier draft used a Markdown `body :: text` column and parsed
  todo lines at render time, but that forced a 3-tier identifier
  fallback to preserve check state across edits. Switching to
  embeds made `PlaybookCheckState.checked_items` lookups trivial
  (`Map.get(checked_items, item.id)`) at the cost of a form-based
  edit UI in TW-4 — accepted because:

    * Trading-time editing is rare (you edit playbooks deliberately
      between sessions, not during one).
    * Freeform live note-taking has its own home in `Trading.Note`
      (LON-182).
    * Future per-item metadata (priority, color, journal link) drops
      in as new embed attrs without parser changes.

  ## 3-version cap (manual delete on over-cap)

  The chain is capped at 3 versions per `(user_id, kind, name)`. On a
  4th `:create_version` attempt:

      {:error, %Ash.Error.Changes.InvalidChanges{
        message: "This playbook has 3 versions already — delete an
                  older version at /trading/edit before saving a new one."
      }}

  Deliberate UX choice (LON-181 revision): the original spec
  auto-deleted the oldest version, but losing trader-written history
  silently is the wrong default. Manual delete forces an intentional
  discard.

  ## Concurrency

  `:create_version` runs inside an Ash transaction. The pre-insert
  count check + the row insert + the prior-version `active: false`
  flip are serialized via a row lock on the `(user_id, kind, name)`
  group — two concurrent saves can't both pass the count check and
  create a 4th row.

  ## `:update_items` typo-fix path

  Small edits (renaming an item, swapping order) don't deserve a new
  history entry. `:update_items` mutates the active row in place
  without bumping `:version`. Use this for quick fixes; use
  `:create_version` when the playbook's intent actually changed.
  Item UUIDs preserved across update, so check state stays intact.

  ## Cascade on delete

  Deleting a playbook (any version) cascades to its
  `PlaybookCheckState` rows via the DB-level `ON DELETE CASCADE` on
  the FK. Set in the migration. Per epic spec.
  """

  use Ash.Resource,
    otp_app: :long_or_short,
    domain: LongOrShort.Trading,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  require Ash.Query

  alias LongOrShort.Trading.PlaybookItem

  @version_cap 3

  postgres do
    table "trading_playbooks"
    repo LongOrShort.Repo

    references do
      reference :user, on_delete: :delete
    end
  end

  identities do
    identity :unique_version_in_chain, [:user_id, :kind, :name, :version]
  end

  attributes do
    uuid_v7_primary_key :id
    create_timestamp :inserted_at

    attribute :kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:rules, :setup]

      description ~s(`:rules` for daily rules, `:setup` for entry-checklist playbooks.)
    end

    attribute :name, :string do
      allow_nil? false
      public? true

      description """
      User-facing label, e.g. `"Daily rules"`, `"Long setup"`,
      `"Gap-up setup"`. Multiple `:setup` playbooks per user are
      expected; each has a distinct `name`.
      """
    end

    attribute :items, {:array, PlaybookItem} do
      allow_nil? false
      public? true
      default []

      description """
      Ordered list of embedded items. Position in the list is the
      display order. Each item has a stable UUID (`PlaybookItem.id`)
      used as the key in `PlaybookCheckState.checked_items`.
      """
    end

    attribute :version, :integer do
      allow_nil? false
      public? true
      default 1

      description """
      Monotonic per-chain version. The latest version in a
      `(user_id, kind, name)` chain has `active: true`. Capped at
      `#{@version_cap}` per chain — see moduledoc.
      """
    end

    attribute :active, :boolean do
      allow_nil? false
      public? true
      default true

      description """
      Exactly one row per `(user_id, kind, name)` chain is `active`
      at a time. `:create_version` flips prior rows to `false`
      atomically when inserting the new latest.
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

  @create_fields [:user_id, :kind, :name, :items]
  @update_fields [:items]

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept @create_fields
    end

    update :update do
      primary? true
      accept @update_fields
      # `items` is an embed array — Ash can't apply it atomically
      # via SQL. Round-trip through Elixir is fine; updates are
      # infrequent (deliberate trader actions, not high-throughput).
      require_atomic? false
    end

    # Keystone write. Inserts a new row in the chain with the next
    # version number; flips prior versions' `active` flag; enforces
    # the version cap. Wrapped in a transaction with row-level
    # serialization so concurrent saves can't both pass the count
    # check and create a 4th row.
    create :create_version do
      accept @create_fields
      transaction? true

      change before_action(fn changeset, _ctx ->
               user_id = Ash.Changeset.get_attribute(changeset, :user_id)
               kind = Ash.Changeset.get_attribute(changeset, :kind)
               name = Ash.Changeset.get_attribute(changeset, :name)

               with {:ok, existing} <- fetch_chain_for_update(user_id, kind, name),
                    :ok <- check_cap(existing),
                    :ok <- deactivate_prior(existing) do
                 next_version = (existing |> Enum.map(& &1.version) |> Enum.max(fn -> 0 end)) + 1
                 Ash.Changeset.force_change_attribute(changeset, :version, next_version)
               else
                 {:error, reason} -> Ash.Changeset.add_error(changeset, reason)
               end
             end)
    end

    # Typo-fix path — mutates `:items` of the currently-active row in
    # place. Does NOT bump `:version`. Item UUIDs survive any edit
    # the user passes through here (caller is responsible for keeping
    # existing item IDs in the new list), so check state stays bound.
    update :update_items do
      accept @update_fields
      require_atomic? false
    end

    # All `active: true` playbooks for a user — the canonical "what
    # the trader is using today" set. Returns rules + setups together;
    # callers can group client-side by `:kind`.
    read :read_active do
      argument :user_id, :uuid_v7, allow_nil?: false

      filter expr(user_id == ^arg(:user_id) and active == true)
      prepare build(sort: [kind: :asc, name: :asc])
    end

    # Full version history for one chain. Used by /trading/edit
    # (TW-4) to render the "previous versions" panel and the
    # delete-this-version action. Sorted newest-first.
    read :read_all_versions do
      argument :user_id, :uuid_v7, allow_nil?: false
      argument :kind, :atom, allow_nil?: false, constraints: [one_of: [:rules, :setup]]
      argument :name, :string, allow_nil?: false

      filter expr(
               user_id == ^arg(:user_id) and
                 kind == ^arg(:kind) and
                 name == ^arg(:name)
             )

      prepare build(sort: [version: :desc])
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

  # ── Internal helpers (called from change steps) ──────────────────

  # Fetches every row in the `(user_id, kind, name)` chain with a
  # row-level lock so concurrent transactions queue behind us. Inside
  # the action's `transaction? true` block, this guarantees the count
  # check and the subsequent insert see consistent state.
  defp fetch_chain_for_update(user_id, kind, name) do
    rows =
      __MODULE__
      |> Ash.Query.filter(user_id == ^user_id and kind == ^kind and name == ^name)
      |> Ash.Query.lock(:for_update)
      |> Ash.read!(authorize?: false)

    {:ok, rows}
  rescue
    e -> {:error, "Failed to lock playbook chain: #{Exception.message(e)}"}
  end

  defp check_cap(rows) when length(rows) >= @version_cap do
    {:error,
     "This playbook has #{@version_cap} versions already — " <>
       "delete an older version at /trading/edit before saving a new one."}
  end

  defp check_cap(_rows), do: :ok

  defp deactivate_prior([]), do: :ok

  defp deactivate_prior(rows) do
    rows
    |> Enum.filter(& &1.active)
    |> Enum.each(fn row ->
      row
      |> Ash.Changeset.for_update(:update, %{})
      |> Ash.Changeset.force_change_attribute(:active, false)
      |> Ash.update!(authorize?: false)
    end)

    :ok
  end
end
