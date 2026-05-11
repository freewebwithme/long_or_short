defmodule LongOrShort.Settings.Setting do
  @moduledoc """
  A single admin-tunable application setting -- LON-125.

  Each row maps a logical configuration key (e.g.
  `"dilution_profile_window_days"`) to a typed value the running
  app reads via `Application.get_env(:long_or_short, key)`. Writes
  go through the admin UI (`ash_admin` at `/admin`); reads happen
  off the in-memory `Application` env, populated at boot by
  `LongOrShort.Settings.Loader`. See the Loader moduledoc for the
  full hydration story.

  ## Why store values as strings + an explicit `:type`

  JSON-like polymorphic value columns make the admin UI awkward --
  the form input would need users to type valid literal syntax
  (`true` vs `"true"` vs `1` etc.). Splitting into a `string`
  value + `atom` type lets the form render a plain text input and
  the Loader cast at hydration time, surfacing misconfiguration
  during boot rather than at first read.

  Supported types and their cast rules (see Loader for the actual
  implementation):

  | `:type`   | `:value` examples       | Cast result                    |
  | --------- | ----------------------- | ------------------------------ |
  | `:integer`| `"180"` / `"30"`        | Elixir integer                 |
  | `:decimal`| `"5.25"` / `"0"`        | `%Decimal{}`                   |
  | `:boolean`| `"true"` / `"false"`    | `true` / `false`               |
  | `:atom`   | `"singapore"`           | `:singapore` via `String.to_existing_atom/1` |
  | `:string` | `"anything"`            | the string itself              |

  ## Why `:updated_by` is nullable

  The Loader and seed scripts run as `SystemActor` -- they have no
  `User` to attribute. Admin UI edits, however, run as the
  authenticated admin user and populate the FK. Audit-style "who
  changed this" queries can filter `is_nil(updated_by_id)` to find
  system-managed rows.

  ## Policies

  Mirrors the Filing / FilingAnalysis pattern:

    * `SystemActor` bypass -- the Loader reads every row at boot.
    * `:admin` bypass -- full CRUD via `ash_admin`.
    * Everyone else (trader, anonymous) -- **forbidden, no read**.
      Settings can carry operational-ish values, and there's no
      trader workflow that needs them today.
  """

  use Ash.Resource,
    otp_app: :long_or_short,
    domain: LongOrShort.Settings,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAdmin.Resource],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "settings"
    repo LongOrShort.Repo

    references do
      reference :updated_by, on_delete: :nilify, on_update: :update
    end
  end

  identities do
    identity :unique_key, [:key]
  end

  attributes do
    uuid_v7_primary_key :id

    create_timestamp :inserted_at
    update_timestamp :updated_at

    attribute :key, :string do
      allow_nil? false
      public? true

      description """
      Settings key -- becomes the `key` argument to
      `Application.put_env(:long_or_short, atom_key, value)` at
      boot. Must correspond to an atom referenced somewhere in the
      codebase (the Loader uses `String.to_existing_atom/1` to
      prevent arbitrary atom creation -- security + memory).
      """
    end

    attribute :value, :string do
      allow_nil? false
      public? true

      description """
      Raw string value. Cast to the type indicated by `:type` at
      hydration time. Plain string storage keeps the admin UI
      input simple (one text field, no JSON literals).
      """
    end

    attribute :type, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:integer, :decimal, :boolean, :atom, :string]
      description "Type the Loader casts `:value` to before `put_env`."
    end

    attribute :description, :string do
      public? true

      description """
      Human-readable note shown in the admin UI -- explains what
      the setting controls and any tuning guidance. Optional but
      strongly encouraged for every row.
      """
    end

    attribute :default_value, :string do
      public? true

      description """
      The in-code default this row overrides. Recorded as metadata
      so an admin can compare current vs default at a glance.
      Not used at runtime -- the actual fallback when a key is
      missing is the in-code call site's default. Optional.
      """
    end
  end

  relationships do
    belongs_to :updated_by, LongOrShort.Accounts.User do
      attribute_writable? true
      public? true

      description """
      The admin who last updated this row. Nullable -- Loader and
      seed paths run as `SystemActor` and leave this `nil`.
      """
    end
  end

  @fields [:key, :value, :type, :description, :default_value, :updated_by_id]

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept @fields
    end

    update :update do
      primary? true
      require_atomic? false
      accept @fields
    end

    read :by_key do
      description "Fetch a single setting by its `:key` (returns nil when missing)."
      argument :key, :string, allow_nil?: false
      get? true
      filter expr(key == ^arg(:key))
    end
  end

  # ─────────────────────────────────────────────────────────────────────
  # Policies -- SystemActor + admin bypass; everyone else forbidden.
  # No `policy action_type(:read) ... actor_present()` because traders
  # have no read access to settings either (operational data).
  # ─────────────────────────────────────────────────────────────────────
  policies do
    bypass actor_attribute_equals(:system?, true) do
      authorize_if always()
    end

    bypass actor_attribute_equals(:role, :admin) do
      authorize_if always()
    end
  end

  # ─────────────────────────────────────────────────────────────────────
  # ash_admin DSL -- drives the UI at `/admin`.
  # ─────────────────────────────────────────────────────────────────────
  admin do
    resource_group :settings
    table_columns [:key, :type, :value, :description, :updated_at]
  end
end
