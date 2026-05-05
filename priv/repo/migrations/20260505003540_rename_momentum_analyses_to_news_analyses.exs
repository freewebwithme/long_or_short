defmodule LongOrShort.Repo.Migrations.RenameMomentumAnalysesToNewsAnalyses do
  @moduledoc """
  Rename `momentum_analyses` table to `news_analyses` (LON-89).

  The resource was renamed from `MomentumAnalysis` to `NewsAnalysis`
  because the broad-with-default `TradingProfile` schema (LON-88)
  supports multiple trading styles — "Momentum" became misleading for
  swing/position/large-cap users receiving the same analysis shape.

  Hand-written rather than auto-generated: `mix ash.codegen` would
  detect this as "delete old + add new" (data-destroying), since Ash
  snapshots are tracked per resource. The snapshot file was manually
  moved alongside this migration so future codegen runs use
  `priv/resource_snapshots/repo/news_analyses/` as the baseline.
  """
  use Ecto.Migration

  def up do
    rename table(:momentum_analyses), to: table(:news_analyses)

    execute """
    ALTER TABLE news_analyses
      RENAME CONSTRAINT momentum_analyses_article_id_fkey
      TO news_analyses_article_id_fkey
    """

    execute """
    ALTER INDEX momentum_analyses_unique_article_index
      RENAME TO news_analyses_unique_article_index
    """
  end

  def down do
    execute """
    ALTER INDEX news_analyses_unique_article_index
      RENAME TO momentum_analyses_unique_article_index
    """

    execute """
    ALTER TABLE news_analyses
      RENAME CONSTRAINT news_analyses_article_id_fkey
      TO momentum_analyses_article_id_fkey
    """

    rename table(:news_analyses), to: table(:momentum_analyses)
  end
end
