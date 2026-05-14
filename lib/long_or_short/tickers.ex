defmodule LongOrShort.Tickers do
  @moduledoc """
  Tickers domain — master data for tradable symbols and per-user watchlists.

  This domain owns the canonical record for each symbol (BTBD, AAPL, etc.)
  and is referenced by other domains (News, future Prices) via foreign keys.
  It also owns `WatchlistItem` — the DB-backed per-user watchlist that
  replaces the static `priv/tracked_tickers.txt` trader-watchlist semantics.

  ## Code interface

   All functions accept an `actor:` option and will be authorized against
   the relevant resource's policies.

       Tickers.list_active_tickers(actor: current_user)
       Tickers.upsert_ticker_by_symbol(
         %{symbol: "BTBD"},
         actor: SystemActor.new()
       )

       Tickers.add_to_watchlist(%{user_id: user.id, ticker_id: ticker.id}, actor: user)
       Tickers.remove_from_watchlist(item_id, actor: user)
       Tickers.list_watchlist(user.id, actor: user)

  ## Cross-resource aggregators

  Beyond the action-backed code interface above, the domain exposes
  aggregators that compose multiple resources into a ticker-scoped
  view. These do not take an `actor:` — they operate on public
  regulatory data where per-user scoping has no semantic meaning
  (same ticker → same answer for every consumer).

      Tickers.get_dilution_profile(ticker.id)        # LON-116, Stage 4
  """

  use Ash.Domain

  resources do
    resource LongOrShort.Tickers.Ticker do
      define :create_ticker, action: :create
      define :update_ticker, action: :update
      define :update_ticker_price, action: :update_price, args: [:last_price]
      define :upsert_ticker_by_symbol, action: :upsert_by_symbol
      define :get_ticker_by_symbol, action: :by_symbol, args: [:symbol]
      define :get_ticker_by_cik, action: :read, get_by: [:cik]
      define :list_active_tickers, action: :active
      define :list_tickers, action: :read
      define :destroy_ticker, action: :destroy
      define :search_tickers, action: :search, args: [:query]
    end

    resource LongOrShort.Tickers.WatchlistItem do
      define :add_to_watchlist, action: :add
      define :remove_from_watchlist, action: :destroy
      define :list_watchlist, action: :list_for_user, args: [:user_id]
      define :list_all_watchlist_items, action: :list_all
    end

    resource LongOrShort.Tickers.SmallCapUniverseMembership do
      define :upsert_small_cap_membership, action: :upsert_observed
      define :list_active_small_cap_memberships, action: :list_active
    end
  end

  @doc """
  All distinct ticker symbols across every user's watchlist.

  Returns an uppercased, deduplicated list ordered by `WatchlistItem`
  insertion time (oldest first) so callers can apply FIFO-style
  eviction when a cap is reached.

  System-only: bypasses policies. The single intended caller is
  `Tickers.Sources.FinnhubStream`, which uses this to compute the
  global live-price WebSocket subscription union. UI code paths must
  go through `list_watchlist/2` with an actor.
  """
  @spec all_watchlist_symbols() :: [String.t()]
  def all_watchlist_symbols do
    case list_all_watchlist_items(authorize?: false) do
      {:ok, items} ->
        items
        |> Enum.map(&String.upcase(&1.ticker.symbol))
        |> Enum.uniq()

      _ ->
        []
    end
  end

  @doc """
  All distinct ticker symbols currently in the small-cap universe.

  Returns an uppercased, deduplicated list ordered by membership
  insertion time (oldest first). System-only — bypasses policies. The
  intended caller is the Phase 2 Tier 1 filing extractor worker
  (LON-135); UI code paths should not depend on this.
  """
  @spec small_cap_symbols() :: [String.t()]
  def small_cap_symbols do
    case list_active_small_cap_memberships(authorize?: false) do
      {:ok, items} ->
        items
        |> Enum.map(&String.upcase(&1.ticker.symbol))
        |> Enum.uniq()

      _ ->
        []
    end
  end

  @doc """
  All distinct ticker IDs currently in the small-cap universe.

  Sibling of `small_cap_symbols/0` — returns the FK values so callers
  that need to scope an `Ash.Query.filter(ticker_id in ^...)` don't
  have to re-resolve symbols to ids. System-only, bypasses policies.
  """
  @spec small_cap_ticker_ids() :: [Ash.UUID.t()]
  def small_cap_ticker_ids do
    case list_active_small_cap_memberships(authorize?: false) do
      {:ok, items} ->
        items
        |> Enum.map(& &1.ticker_id)
        |> Enum.uniq()

      _ ->
        []
    end
  end

  @doc """
  Per-ticker dilution profile — LON-116, Stage 4.

  Aggregates `LongOrShort.Filings.FilingAnalysis` rows into a single
  dilution overhang summary: severity, active ATM lifecycle, pending
  S-1, warrant overhang, recent reverse splits, `data_completeness`.

  See `LongOrShort.Tickers.DilutionProfile` for the full output
  shape, the hybrid window-vs-lifecycle aggregation model, and the
  Phase 1 simplifications.

  Consumers:

    * **Stage 5** (LON-117) — `NewsAnalyzer` injects this into its
      LLM prompt so news verdicts become dilution-aware.
    * **Stage 6** — `/dilution/:ticker` UI renders it directly.

  Options:

    * `:as_of` — `DateTime.t()`; reference time for the window
      cutoff. Test-only override.
  """
  @spec get_dilution_profile(Ash.UUID.t(), keyword()) ::
          LongOrShort.Tickers.DilutionProfile.t()
  def get_dilution_profile(ticker_id, opts \\ []) do
    LongOrShort.Tickers.DilutionProfile.get(ticker_id, opts)
  end
end
