defmodule LongOrShort.News.EventsTest do
  @moduledoc """
  Unit tests for the PubSub wrapper module.

  These are basically smoke tests — Events is a thin facade over
  Phoenix.PubSub. The point is to lock in the contract (topic name,
  message tuple shape) so other call sites can rely on it without
  knowing the internals.
  """

  use ExUnit.Case, async: true

  alias LongOrShort.News.Events

  describe "subscribe/0 + broadcast_new_article/1" do
    test "subscriber receives broadcast message" do
      Events.subscribe()

      article = %LongOrShort.News.Article{title: "Test"}
      :ok = Events.broadcast_new_article(article)

      assert_receive {:new_article, %LongOrShort.News.Article{title: "Test"}}, 100
    end

    test "non-subscribed processes do not receive the broadcast" do
      # We don't subscribe here.
      article = %LongOrShort.News.Article{title: "Should not arrive"}
      :ok = Events.broadcast_new_article(article)

      refute_receive {:new_article, _}, 100
    end

    test "multiple subscribers all receive the broadcast" do
      Events.subscribe()

      parent = self()

      task =
        Task.async(fn ->
          Events.subscribe()
          send(parent, :subscribed)

          receive do
            {:new_article, article} -> article.title
          after
            500 -> :timeout
          end
        end)

      assert_receive :subscribed, 500

      article = %LongOrShort.News.Article{title: "Fan-out"}
      :ok = Events.broadcast_new_article(article)

      # Both this process and the task should receive
      assert_receive {:new_article, %LongOrShort.News.Article{title: "Fan-out"}}, 100
      assert Task.await(task) == "Fan-out"
    end
  end
end
