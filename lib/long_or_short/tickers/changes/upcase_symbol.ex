defmodule LongOrShort.Tickers.Changes.UpcaseSymbol do
  @moduledoc """
  Normalizes `symbol` to trimmed uppercase.

  External sources disagree on casing — Benzinga sends "btbd" while SEC
  uses "BTBD". Normalizing on write keeps lookups and unique constraints
  consistent.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :symbol) do
      nil ->
        changeset

      symbol when is_binary(symbol) ->
        Ash.Changeset.force_change_attribute(
          changeset,
          :symbol,
          symbol |> String.trim() |> String.upcase()
        )

      _ ->
        changeset
    end
  end
end
