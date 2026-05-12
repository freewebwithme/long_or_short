defmodule LongOrShortWeb.Live.TickerSearchHelper do
  @moduledoc """
  Shared search logic for the `TickerAutocomplete` component used by 4
  LiveViews (`feed`, `analyze`, `dashboard`, `watchlist`).

  Only the *search* step is shared — each LiveView's select / clear
  handlers do view-specific work (load articles, apply filter, add to
  watchlist) and stay per-view. Assign key names also stay per-view;
  the helper returns a plain tuple so callers wire it into their own
  `:foo_query` / `:foo_results` assigns.

  Extracted in LON-145 from the 2026-05-12 code duplication audit.
  """

  alias LongOrShort.Tickers

  @doc """
  Runs a ticker search for the given query as the given actor.

  Returns `{trimmed_query, results}`. Empty / whitespace queries skip
  the DB and return `[]`. Authorization errors fall through to `[]`
  rather than raising — the caller's UI shows "no results" instead of
  crashing the LiveView.
  """
  @spec search(String.t(), term()) :: {String.t(), list()}
  def search(query, actor) do
    trimmed = String.trim(query)

    results =
      case trimmed do
        "" ->
          []

        q ->
          case Tickers.search_tickers(q, actor: actor) do
            {:ok, list} -> list
            _ -> []
          end
      end

    {trimmed, results}
  end
end
