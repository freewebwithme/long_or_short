defmodule LongOrShort.Repo.Migrations.DropRepetitionAnalysis do
  @moduledoc """
  Drop the `repetition_analysis` table (LON-80). The resource is
  superseded by `LongOrShort.Analysis.NewsAnalysis` (LON-79/LON-89);
  the single-axis repetition value is now one column on NewsAnalysis
  (`:repetition_count` + `:repetition_summary`).

  Hand-written because we deleted the resource module and its snapshot
  directory in the same change — `mix ash.codegen` no longer has a
  baseline to diff from. The down/0 mirrors the original
  `20260429184347_add_repetition_analyses.exs` migration so a
  rollback restores the table to its pre-drop shape (data is lost).
  """
  use Ecto.Migration

  def up do
    drop_if_exists index(:repetition_analysis, [:article_id])
    drop_if_exists index(:repetition_analysis, [:fatigue_level])
    drop_if_exists index(:repetition_analysis, [:article_id, :status])
    drop constraint(:repetition_analysis, "repetition_analysis_article_id_fkey")
    drop table(:repetition_analysis)
  end

  def down do
    create table(:repetition_analysis, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("uuidv7()"), primary_key: true

      add :created_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :is_repetition, :boolean
      add :theme, :text
      add :repetition_count, :bigint, null: false, default: 1
      add :related_article_ids, {:array, :uuid}, null: false, default: []
      add :fatigue_level, :text
      add :reasoning, :text
      add :model_used, :text
      add :tokens_used_input, :bigint
      add :tokens_used_output, :bigint
      add :status, :text, null: false, default: "pending"
      add :error_message, :text

      add :article_id,
          references(:articles,
            column: :id,
            name: "repetition_analysis_article_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :restrict,
            on_update: :update_all
          ),
          null: false
    end

    create index(:repetition_analysis, [:article_id])
    create index(:repetition_analysis, [:fatigue_level])
    create index(:repetition_analysis, [:article_id, :status])
  end
end
