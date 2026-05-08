defmodule LongOrShort.Repo.Migrations.AddUserIdToNewsAnalyses do
  @moduledoc """
  LON-109: add `user_id` to `news_analyses`, switch identity from
  per-article to per-(article × user), and add a composite index for
  the per-user history scan that drives the /analyze history surface
  (LON-108).

  ## Backfill rationale

  Solo deployment today: 11 existing analyses, all triggered by the
  original trader (UUIDv7 is timestamp-ordered, so `ORDER BY id LIMIT 1`
  on `users WHERE role = 'trader'` resolves to the oldest trader — the
  original solo account). Pre-Phase-4 backfill is unambiguous.

  Once external traffic exists every new row carries `user_id` from
  the analyzer write path, so this is a one-time migration, not a
  recurring concern.

  ## Why split into nullable-add + backfill + NOT NULL

  Adding `user_id` directly with `null: false` would fail the existing
  rows. The three-phase approach keeps the migration atomic (one
  transaction) while making the intermediate "nullable" state never
  observable outside the migration.
  """

  use Ecto.Migration

  def up do
    # Phase 1: add the FK column nullable so the existing 11 rows
    # don't violate NOT NULL during the migration window.
    alter table(:news_analyses) do
      add :user_id,
          references(:users,
            column: :id,
            name: "news_analyses_user_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :restrict,
            on_update: :update_all
          ),
          null: true
    end

    # Phase 2: backfill all existing rows to the oldest trader user.
    execute """
    UPDATE news_analyses
    SET user_id = (
      SELECT id FROM users
      WHERE role = 'trader'
      ORDER BY id
      LIMIT 1
    )
    WHERE user_id IS NULL
    """

    # Phase 3: enforce NOT NULL once every row is backfilled.
    execute "ALTER TABLE news_analyses ALTER COLUMN user_id SET NOT NULL"

    # Phase 4: composite index for the per-user history scan
    # (LON-108 `:recent` action filters by user_id, sorts by id desc).
    create index(:news_analyses, [:user_id, :id], name: "news_analyses_user_id_id_index")

    # Phase 5: identity swap — drop article-only uniqueness, add the
    # composite (article_id, user_id). Two users can now analyze the
    # same article and produce distinct rows.
    drop_if_exists unique_index(:news_analyses, [:article_id],
                     name: "news_analyses_unique_article_index"
                   )

    create unique_index(:news_analyses, [:article_id, :user_id],
             name: "news_analyses_unique_article_user_index"
           )
  end

  def down do
    drop_if_exists unique_index(:news_analyses, [:article_id, :user_id],
                     name: "news_analyses_unique_article_user_index"
                   )

    create unique_index(:news_analyses, [:article_id], name: "news_analyses_unique_article_index")

    drop_if_exists index(:news_analyses, [:user_id, :id], name: "news_analyses_user_id_id_index")

    drop constraint(:news_analyses, "news_analyses_user_id_fkey")

    alter table(:news_analyses) do
      remove :user_id
    end
  end
end
