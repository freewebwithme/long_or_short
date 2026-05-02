defmodule LongOrShort.Indices.Events do
  @moduledoc """
  PubSub facade for index ticks. Mirror of News.Events
  """

  @topic "indices"

  def subscribe do
    Phoenix.PubSub.subscribe(LongOrShort.PubSub, @topic)
  end

  def broadcast(label, payload) do
    Phoenix.PubSub.broadcast(LongOrShort.PubSub, @topic, {:index_tick, label, payload})
  end
end
