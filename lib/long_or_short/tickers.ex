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
end
