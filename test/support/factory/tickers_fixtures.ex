defmodule LongOrShort.TickersFixtures do
  @moduledoc """
  Test fixtures for the Tickers domain.

  Provides small helpers for creating Ticker and WatchlistItem records in
  tests without pulling in a full factory library. When relationships grow
  we can migrate these to `Ash.Generator` or `ex_machina` — for now,
  deterministic helpers are simpler.
  """

  alias LongOrShort.Accounts.SystemActor
  alias LongOrShort.Tickers

  @doc """
  Returns a map of valid attributes for creating a Ticker.
  Symbol is auto-generated to avoid unique-index collisions.

  ## Examples

      iex> valid_ticker_attrs()
      %{symbol: "TEST1", ...}

      iex> valid_ticker_attrs(%{symbol: "BTBD", exchange: :nasdaq})
      %{symbol: "BTBD", exchange: :nasdaq, ...}
  """
  def valid_ticker_attrs(overrides \\ %{}) do
    unique = System.unique_integer([:positive])

    Map.merge(
      %{
        symbol: "TEST#{unique}",
        company_name: "Test Company #{unique}",
        exchange: :nasdaq,
        is_active: true
      },
      overrides
    )
  end

  @doc """
  Creates a Ticker using the SystemActor (bypass policies).
  Use this when the test is not about authorization.
  """
  def build_ticker(overrides \\ %{}) do
    attrs = valid_ticker_attrs(overrides)

    case Tickers.create_ticker(attrs, actor: SystemActor.new()) do
      {:ok, ticker} ->
        ticker

      {:error, error} ->
        raise """
        Failed to create ticker fixture.
        attrs: #{inspect(attrs)}
        error: #{inspect(error)}
        """
    end
  end

  @doc """
  Creates a WatchlistItem. Lazily creates a trader user and ticker if
  `:user_id` or `:ticker_id` are not supplied.
  """
  def build_watchlist_item(overrides \\ %{}) do
    import LongOrShort.AccountsFixtures, only: [build_trader_user: 0]

    user_id = Map.get_lazy(overrides, :user_id, fn -> build_trader_user().id end)
    ticker_id = Map.get_lazy(overrides, :ticker_id, fn -> build_ticker().id end)

    case Tickers.add_to_watchlist(%{user_id: user_id, ticker_id: ticker_id}, authorize?: false) do
      {:ok, item} ->
        item

      {:error, error} ->
        raise """
        Failed to create watchlist_item fixture.
        user_id: #{user_id}, ticker_id: #{ticker_id}
        error: #{inspect(error)}
        """
    end
  end
end
