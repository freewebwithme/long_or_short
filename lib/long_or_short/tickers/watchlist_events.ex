defmodule LongOrShort.Tickers.WatchlistEvents do
  @moduledoc """
  PubSub interface for watchlist mutations.

  Producers (the /watchlist LiveView) call `broadcast_changed/1` after a
  successful add or remove. Two topics receive every change:

  - `"watchlist:user:<user_id>"` — one topic per user, used by per-session
    consumers like the dashboard LiveView so each browser session is
    insulated from other users' mutations.
  - `"watchlist:any"` — a single global topic, used by system-wide
    consumers that need to react to *any* user's change without having to
    enumerate users (e.g. `Tickers.Sources.FinnhubStream` recomputes its
    WebSocket subscription set on every change).

  ## Message format

      {:watchlist_changed, user_id}

  Payload is intentionally minimal: subscribers re-fetch the current
  state. This avoids stale snapshots in transit and keeps payload size
  constant regardless of list length.
  """

  @any_topic "watchlist:any"

  defp topic(user_id), do: "watchlist:user:#{user_id}"

  @doc """
  Subscribe the calling process to watchlist events for the given user.
  """
  @spec subscribe(Ash.UUID.t()) :: :ok | {:error, term()}
  def subscribe(user_id) do
    Phoenix.PubSub.subscribe(LongOrShort.PubSub, topic(user_id))
  end

  @doc """
  Subscribe the calling process to watchlist events for *any* user.

  Intended for system-wide consumers that maintain global derived state
  (e.g. the live-price WebSocket subscription set).
  """
  @spec subscribe_any() :: :ok | {:error, term()}
  def subscribe_any do
    Phoenix.PubSub.subscribe(LongOrShort.PubSub, @any_topic)
  end

  @doc """
  Broadcast that the given user's watchlist has changed.

  Fans out to both the per-user topic and the global `"watchlist:any"`
  topic in a single call, so producers don't need to know which
  consumers exist.
  """
  @spec broadcast_changed(Ash.UUID.t()) :: :ok | {:error, term()}
  def broadcast_changed(user_id) do
    msg = {:watchlist_changed, user_id}
    Phoenix.PubSub.broadcast(LongOrShort.PubSub, topic(user_id), msg)
    Phoenix.PubSub.broadcast(LongOrShort.PubSub, @any_topic, msg)
  end
end
