defmodule LongOrShort.Tickers.WatchlistEvents do
  @moduledoc """
  Per-user PubSub interface for watchlist mutations.

  Producers (the /watchlist LiveView) call `broadcast_changed/1` after a
  successful add or remove. Consumers (the dashboard LiveView) call
  `subscribe/1` in `mount/3` to be notified within the same browser
  session and re-render derived state (current symbols, "My watchlist
  news" widget) without a manual reload.

  ## Topic

  `"watchlist:user:<user_id>"` — one topic per user. Keeps each session
  insulated from other users' mutations.

  ## Message format

      {:watchlist_changed, user_id}

  Payload is intentionally minimal: subscribers re-fetch the current
  state via `Tickers.list_watchlist/2`. This avoids stale snapshots
  in transit and keeps payload size constant regardless of list length.
  """

  defp topic(user_id), do: "watchlist:user:#{user_id}"

  @doc """
  Subscribe the calling process to watchlist events for the given user.
  """
  @spec subscribe(Ash.UUID.t()) :: :ok | {:error, term()}
  def subscribe(user_id) do
    Phoenix.PubSub.subscribe(LongOrShort.PubSub, topic(user_id))
  end

  @doc """
  Broadcast that the given user's watchlist has changed.
  """
  @spec broadcast_changed(Ash.UUID.t()) :: :ok | {:error, term()}
  def broadcast_changed(user_id) do
    Phoenix.PubSub.broadcast(
      LongOrShort.PubSub,
      topic(user_id),
      {:watchlist_changed, user_id}
    )
  end
end
