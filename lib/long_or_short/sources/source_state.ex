defmodule LongOrShort.Sources.SourceState do
  @moduledoc """
  Persistent polling metadata for each news source.

  Tracks the last successful fetch time and last error per source so
  feeders can avoid redundant API calls and duplicate broadcasts across
  server restarts.

  One row per source; `:source` is the primary key.
  """

  use Ash.Resource,
    otp_app: :long_or_short,
    domain: LongOrShort.Sources,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    primary_read_warning?: false

  postgres do
    table "source_states"
    repo LongOrShort.Repo
  end

  identities do
    identity :unique_source, [:source]
  end

  attributes do
    attribute :source, :atom do
      allow_nil? false
      primary_key? true
      public? true
      constraints one_of: [:finnhub, :sec, :benzinga, :pr_newswire]
    end

    attribute :last_success_at, :utc_datetime_usec do
      allow_nil? true
      public? true
      description "Last time fetch_news completed without error."
    end

    attribute :last_error, :string do
      allow_nil? true
      public? true
      description "Last error message, if any."
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    create :upsert do
      upsert? true
      upsert_identity :unique_source
      accept [:source, :last_success_at, :last_error]
      upsert_fields [:last_success_at, :last_error, :updated_at]
    end

    read :read do
      primary? true
    end
  end

  policies do
    bypass actor_attribute_equals(:system?, true) do
      authorize_if always()
    end

    bypass actor_attribute_equals(:role, :admin) do
      authorize_if always()
    end
  end
end
