defmodule LongOrShort.News.Changes.ComputeContentHash do
  @moduledoc """
  Computes `content_hash` from `title + summary` using SHA-256.

  Acts as a permanent deduplication signal, complementing the
  `[source, external_id, ticker_id]` identity. The ETS-based
  `News.Dedup` provides fast in-memory dedup with a 24h TTL; this
  hash survives in the database as a last-resort safety net against
  articles that arrive with different external IDs but identical
  content (rare but observed in practice with SEC re-filings).
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    title = Ash.Changeset.get_attribute(changeset, :title)
    summary = Ash.Changeset.get_attribute(changeset, :summary)

    hash = compute_hash(title, summary)

    Ash.Changeset.force_change_attribute(changeset, :content_hash, hash)
  end

  # Accepts nil summary - SEC filings often have only a title.
  defp compute_hash(nil, _summary), do: nil

  defp compute_hash(title, summary) when is_binary(title) do
    payload = [title, summary || ""] |> Enum.join("\n")

    :sha256
    |> :crypto.hash(payload)
    |> Base.encode16(case: :lower)
  end

  defp compute_hash(_, _), do: nil
end
