defmodule LongOrShort.Accounts.UserProfile do
  @moduledoc """
  Per-user personal profile — display name, contact info, avatar.

  Distinct from `TradingProfile` (LON-88), which captures trading
  style/preferences. One profile per user, enforced by the
  `:unique_user` identity. The user manages their own profile via
  the `/profile` UI (LON-98).

  ## Why a separate resource (vs columns on `User`)

  Keeps `User` focused on authentication (email, password, role,
  confirmed_at). Lets the personal profile schema grow independently
  — future additions like timezone, locale, notification preferences
  — without bloating the auth resource. Also mirrors the existing
  has_one pattern between `User` and `TradingProfile`.

  ## Policies

  SystemActor and admins bypass all checks. Trader role can read and
  create/upsert — Phase 1 single-user makes `actor_present()`
  sufficient. LON-15 will tighten to "only their own profile" once
  auth hardens (same fate as `TradingProfile`).
  """

  use Ash.Resource,
    otp_app: :long_or_short,
    domain: LongOrShort.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "user_profiles"
    repo LongOrShort.Repo

    references do
      reference :user, on_delete: :delete, on_update: :update
    end
  end

  identities do
    identity :unique_user, [:user_id]
  end

  attributes do
    uuid_v7_primary_key :id
    create_timestamp :created_at
    update_timestamp :updated_at

    attribute :full_name, :string do
      public? true
      description "Display name. Free-text; the form layer trims whitespace."
    end

    attribute :phone, :string do
      public? true

      description """
      Free-text contact number. No E.164 enforcement in Phase 1 —
      formatting + validation deferred until SMS notifications land.
      """
    end

    attribute :avatar_url, :string do
      public? true
      description "URL to externally-hosted profile image. Empty → consumers render initials."
    end
  end

  relationships do
    belongs_to :user, LongOrShort.Accounts.User do
      allow_nil? false
      attribute_writable? true
      public? true
    end
  end

  @fields [:user_id, :full_name, :phone, :avatar_url]

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept @fields
    end

    create :upsert do
      upsert? true
      upsert_identity :unique_user

      accept @fields

      upsert_fields [:full_name, :phone, :avatar_url]
    end

    update :update do
      primary? true
      require_atomic? false
      accept [:full_name, :phone, :avatar_url]
    end

    read :get_by_user do
      get? true
      argument :user_id, :uuid, allow_nil?: false
      filter expr(user_id == ^arg(:user_id))
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
      authorize_if actor_present()
    end

    # Trader can manage their own profile — UserProfile is user-owned
    # config, not system output. Phase 1 single-user, so `actor_present()`
    # is sufficient. LON-15 will tighten to "only the profile's own user".
    policy action_type([:create, :update]) do
      authorize_if actor_present()
    end
  end
end
