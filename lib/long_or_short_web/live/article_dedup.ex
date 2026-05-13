defmodule LongOrShortWeb.Live.ArticleDedup do
  @moduledoc """
  Shared multi-ticker article dedup for news-feed surfaces (LON-157).

  Article rows are persisted per ticker (LON-129 dedup key
  `(source, external_id, symbol)`), so a single Benzinga/Alpaca
  headline that mentions N tickers becomes N rows. On surfaces where
  the trader is scanning a market overview (Morning Brief, dashboard
  cards, feed) that's visual noise — the same headline appears N
  times. This module collapses such rows into a single presentation
  map carrying a list of ticker symbols.

  ## Output shape

  Each row is a plain map with all the original `News.Article` fields
  (struct → map via `Map.from_struct/1`) plus a `:ticker_symbols`
  list. Streams keyed on `:id` still work — the representative
  article's UUID is preserved.

  ## Order

  `dedup/1` returns rows sorted by `published_at` desc (with `id`
  desc as a stable tiebreak). Matches the `Article.morning_brief`
  action's intended `[published_at: :desc, id: :desc]` order. Pre-
  LON-155 the sort key was `id` only, which surfaced recently-
  ingested old articles ahead of newly-published earlier-ingested
  ones — confusing on tab switches.

  ## PubSub path

  Live broadcasts arrive one article at a time. `to_row/1` produces
  the same presentation shape from a single article so the stream
  shape stays uniform. Cross-row collapse for live broadcasts is a
  V2: the same multi-ticker article may arrive N times in quick
  succession; page reload resolves it via `dedup/1`.
  """

  @doc """
  Collapse rows sharing `(source, external_id)` into one presentation
  map per group, sorted newest-published first.
  """
  @spec dedup([map()]) :: [map()]
  def dedup(articles) do
    articles
    |> Enum.group_by(&dedup_key/1)
    |> Enum.map(fn {_key, group} -> collapse(group) end)
    # Two-pass to leverage Elixir's stable sort: id-desc first sets
    # the tiebreak order, then published_at-desc wins on equal
    # timestamps. Matches the action's intended order.
    |> Enum.sort_by(& &1.id, :desc)
    |> Enum.sort_by(& &1.published_at, {:desc, DateTime})
  end

  @doc """
  Wrap a single article into the same presentation shape `dedup/1`
  produces — for PubSub `stream_insert` paths where dedup hasn't been
  applied upstream.
  """
  @spec to_row(map()) :: map()
  def to_row(article) do
    article
    |> Map.from_struct()
    |> Map.put(:ticker_symbols, ticker_symbols_for(article))
  end

  # ── Internals ────────────────────────────────────────────────────

  defp dedup_key(%{external_id: nil, id: id}), do: {:unique, id}
  defp dedup_key(%{source: source, external_id: ext}), do: {source, ext}

  defp collapse([single]), do: do_collapse(single, ticker_symbols_for(single))

  defp collapse([_ | _] = group) do
    # Smallest id = first-inserted variant; gives a stable dom_id
    # across reloads (UUIDv7 is timestamp-ordered).
    representative = Enum.min_by(group, & &1.id)

    symbols =
      group
      |> Enum.flat_map(&ticker_symbols_for/1)
      |> Enum.uniq()

    do_collapse(representative, symbols)
  end

  defp do_collapse(article, ticker_symbols) do
    article
    |> Map.from_struct()
    |> Map.put(:ticker_symbols, ticker_symbols)
  end

  defp ticker_symbols_for(%{ticker: %{symbol: s}}) when is_binary(s), do: [s]
  defp ticker_symbols_for(_), do: []
end
