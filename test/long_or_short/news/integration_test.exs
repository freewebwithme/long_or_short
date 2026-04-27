defmodule LongOrShort.News.IntegrationTest do
  @moduledoc """
  End-to-end test of the news ingestion pipeline.

  This is the keystone test for LON-8: it boots the SourceSupervisor
  with the Dummy source enabled, subscribes to the formal Events
  topic, and verifies that within a small time window an Article
  appears in the DB and a {:new_article, ...} message arrives via
  PubSub.

  Every link in the chain — Pipeline scheduling, Dedup,
  News.ingest_article (with SystemActor), Phoenix.PubSub broadcast,
  Events wrapper — gets exercised by this single test.
  """

  use LongOrShort.DataCase, async: false

  alias LongOrShort.News
  alias LongOrShort.News.Article
  alias LongOrShort.News.Dedup
  alias LongOrShort.News.Events
  alias LongOrShort.News.SourceSupervisor
  alias LongOrShort.News.Sources.Dummy

  setup do
    original = Application.get_env(:long_or_short, :enabled_news_sources)

    on_exit(fn ->
      if original do
        Application.put_env(:long_or_short, :enabled_news_sources, original)
      else
        Application.delete_env(:long_or_short, :enabled_news_sources)
      end
    end)

    Dedup.clear()
    :ok
  end

  test "SourceSupervisor → Dummy → Events broadcast → DB persistence" do
    Application.put_env(:long_or_short, :enabled_news_sources, [Dummy])

    Events.subscribe()
    start_supervised!({SourceSupervisor, [name: :test_source_sup]})

    # Pipeline.init schedules the first poll immediately, so the
    # broadcast should arrive within a small window even allowing for
    # DB upsert latency
    assert_receive {:new_article, %Article{source: :other} = article}, 1_000

    # The article matches one of the Dummy samples
    assert article.title in [
             "BTBD announces new strategic partnership",
             "Apple beats Q2 earnings expectations",
             "Tesla quarterly deliveries up 15% YoY",
             "Nvidia unveils next-generation AI chip",
             "AMD partners with major cloud provider"
           ]

    # And it's persisted in the DB
    {:ok, articles} = News.list_articles(authorize?: false)
    assert length(articles) >= 1
  end
end
