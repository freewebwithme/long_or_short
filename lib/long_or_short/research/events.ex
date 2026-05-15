defmodule LongOrShort.Research.Events do
  @moduledoc """
  PubSub wrapper for the on-demand briefing async flow (LON-172).

  ## Topic shape

  `"research:briefings:user:<user_id>"` — one topic per user. A
  LiveView mounted for `current_user` subscribes once and receives
  every briefing event for that user, regardless of which ticker the
  request was for. The payload carries `ticker_id` (and
  `request_id`), so the consuming view filters / routes per-card.

  Per-user (not per-(user, ticker)) because the trader's session has
  one open view at a time, but multiple parallel `BriefingWorker`
  jobs can be in flight (e.g. trader clicked "Brief" on three feed
  cards in quick succession). A single subscription gathers them all
  and the view dispatches via the embedded `ticker_id`.

  ## Message contract

    * `{:briefing_started, ticker_id, request_id}` — emitted by
      `BriefingWorker` on `perform/1` start. UI uses this to swap the
      "Brief" button for a spinner.
    * `{:briefing_ready, ticker_id, briefing_id, request_id}` —
      emitted after successful generation + persist. `briefing_id` is
      the row to render.
    * `{:briefing_failed, ticker_id, reason, request_id}` — emitted
      on Generator / persist error. UI restores the button and may
      surface the reason.

  `request_id` is a `UUID.uuid4()` string returned by the enqueue
  helper so the caller can correlate started/ready/failed across the
  three messages if it cares (PT-2 may use this for optimistic UI;
  PT-1 just emits, no consumer yet).
  """

  alias LongOrShort.Research.TickerBriefing

  @doc """
  Subscribe the calling process to a user's briefing topic. Typically
  invoked from a LiveView's `mount/3`.
  """
  @spec subscribe_for_user(Ecto.UUID.t()) :: :ok | {:error, term()}
  def subscribe_for_user(user_id) when is_binary(user_id) do
    Phoenix.PubSub.subscribe(LongOrShort.PubSub, topic_for(user_id))
  end

  @doc """
  Emitted at worker `perform/1` entry. `request_id` is the
  caller-provided correlation key.
  """
  @spec broadcast_started(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) :: :ok | {:error, term()}
  def broadcast_started(user_id, ticker_id, request_id) do
    Phoenix.PubSub.broadcast(
      LongOrShort.PubSub,
      topic_for(user_id),
      {:briefing_started, ticker_id, request_id}
    )
  end

  @doc """
  Emitted after the briefing row is persisted. Receivers fetch the
  full row via `Research.get_ticker_briefing(briefing_id)` if they
  want the narrative; passing the id (not the struct) keeps the
  payload light and avoids stale-data corner cases.
  """
  @spec broadcast_ready(TickerBriefing.t(), String.t()) :: :ok | {:error, term()}
  def broadcast_ready(%TickerBriefing{} = briefing, request_id) do
    Phoenix.PubSub.broadcast(
      LongOrShort.PubSub,
      topic_for(briefing.generated_for_user_id),
      {:briefing_ready, briefing.ticker_id, briefing.id, request_id}
    )
  end

  @doc """
  Emitted on Generator or persist failure. `reason` is the raw
  `{:error, term}` term — UIs format it for display.
  """
  @spec broadcast_failed(Ecto.UUID.t(), Ecto.UUID.t(), term(), String.t()) ::
          :ok | {:error, term()}
  def broadcast_failed(user_id, ticker_id, reason, request_id) do
    Phoenix.PubSub.broadcast(
      LongOrShort.PubSub,
      topic_for(user_id),
      {:briefing_failed, ticker_id, reason, request_id}
    )
  end

  @doc """
  The topic string for a user. Exposed for tests; production code
  goes through `subscribe_for_user/1`.
  """
  @spec topic_for(Ecto.UUID.t()) :: String.t()
  def topic_for(user_id), do: "research:briefings:user:#{user_id}"
end
