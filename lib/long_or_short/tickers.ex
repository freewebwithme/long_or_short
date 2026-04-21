defmodule LongOrShort.Tickers do
  @moduledoc """
  Tickers domain — master data for tradable symbols.

  This domain owns the canonical record for each symbol (BTBD, AAPL, etc.)
  and is referenced by other domains (News, future Prices) via foreign keys.

  ## Code interface

   All functions accept an `actor:` option and will be authorized against
   `LongOrShort.Tickers.Ticker` policies.

       Tickers.list_active_tickers(actor: current_user)
       Tickers.upsert_ticker_by_symbol(
         %{symbol: "BTBD"},
         actor: SystemActor.new()
       )
  """

  use Ash.Domain

  resources do
    resource LongOrShort.Tickers.Ticker do
      define :create_ticker, action: :create
      define :update_ticker, action: :update
      define :update_ticker_price, action: :update_price, args: [:last_price]
      define :upsert_ticker_by_symbol, action: :upsert_by_symbol
      define :get_ticker_by_symbol, action: :by_symbol, args: [:symbol]
      define :list_active_tickers, action: :active
      define :list_tickers, action: :read
    end
  end
end
