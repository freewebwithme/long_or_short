defmodule LongOrShort.Analysis.RepetitionAnalysis do
  @moduledoc """
  Repetition analysis result for a single news article.

  Lifecycle: `:start` creates a `:pending` row (only `article_id` known),
  then either `:complete` (filling in the LLM output) or `:fail`
  (recording an error message). Multiple analyses per article are
  allowed — re-runs append rather than overwrite. Use
  `:latest_for_article` to fetch the most recent one.

  Policies follow the existing SystemActor bypass pattern (LON-15
  will replace this).
  """

  use Ash.Resource,
    otp_app: :long_or_short,
    domain: LongOrShort.Analysis,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "repetition_analysis"
    repo LongOrShort.Repo

    references do
      reference :article, on_delete: :restrict, on_update: :update
    end

    custom_indexes do
      index [:article_id]
      index [:fatigue_level]
      index [:article_id, :status]
    end
  end

  attributes do
    uuid_v7_primary_key :id

    create_timestamp :created_at
    update_timestamp :updated_at

    attribute :is_repetition, :boolean do
      public? true
      description "Whether the article repeats a recent theme. Nil until :complete."
    end

    attribute :theme, :string do
      public? true
      description "Repeated theme label, when is_repetition? is true."
    end

    attribute :repetition_count, :integer do
      allow_nil? false
      public? true
      default 1
      description "Nth occurrence of the theme (this article included)."
    end

    attribute :related_article_ids, {:array, :uuid} do
      public? true
      default []
    end

    attribute :fatigue_level, :atom do
      public? true
      constraints one_of: [:low, :medium, :high]
      description "Reader-fatigue heuristic. nil until :complete."
    end

    attribute :reasoning, :string do
      public? true
      description "LLM-produced rationale. nil until :complete."
    end

    attribute :model_used, :string do
      public? true
      description ~s(Provider model id, e.g. "claude-opus-4-7".)
    end

    attribute :tokens_used_input, :integer do
      public? true
    end

    attribute :tokens_used_output, :integer do
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :pending
      constraints one_of: [:pending, :complete, :failed]
    end

    attribute :error_message, :string do
      public? true
      description "Populated when status = :failed."
    end
  end

  relationships do
    belongs_to :article, LongOrShort.News.Article do
      allow_nil? false
      attribute_writable? true
      public? true
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true

      accept [
        :article_id,
        :is_repetition,
        :theme,
        :repetition_count,
        :related_article_ids,
        :fatigue_level,
        :reasoning,
        :model_used,
        :tokens_used_input,
        :tokens_used_output,
        :status,
        :error_message
      ]
    end

    create :start do
      description "Create a :pending analysis row at the moment work begins"
      accept [:article_id]
      change set_attribute(:status, :pending)
    end

    update :complete do
      description "Record a successful analysis result."

      accept [
        :is_repetition,
        :theme,
        :repetition_count,
        :related_article_ids,
        :fatigue_level,
        :reasoning,
        :model_used,
        :tokens_used_input,
        :tokens_used_output
      ]

      validate present([:is_repetition, :fatigue_level, :reasoning])
      change set_attribute(:status, :complete)
    end

    update :fail do
      description "Record an analysis failure."
      accept [:error_message]
      validate present(:error_message)
      change set_attribute(:status, :failed)
    end

    read :latest_for_article do
      argument :article_id, :uuid, allow_nil?: false
      filter expr(article_id == ^arg(:article_id))

      prepare build(sort: [created_at: :desc], limit: 1)
    end

    read :for_article do
      argument :article_id, :uuid, allow_nil?: false

      filter expr(article_id == ^arg(:article_id))

      prepare build(sort: [created_at: :desc])
    end

    read :pending_for_article do
      description """
      Returns the in-flight :pending analysis for the given article (if any).

      Used by `RepetitionAnalyzer.analyze/1` as a soft race guard against
      concurrent triggers on the same article. A stronger guarantee would
      require a partial unique index `WHERE status = :pending`; MVP relies
      on this check.
      """

      argument :article_id, :uuid, allow_nil?: false
      filter expr(article_id == ^arg(:article_id) and status == :pending)
      prepare build(sort: [created_at: :desc], limit: 1)
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
  end
end
