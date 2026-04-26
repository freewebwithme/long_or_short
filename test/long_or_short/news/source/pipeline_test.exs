defmodule LongOrShort.News.Source.PipelineTest do
  @moduledoc """
  Tests for the polling pipeline helper.

  Strategy: define a single MockSource module whose `fetch_news/1` and
  `parse_response/1` look up their behavior from the state map passed
  in by each test. This keeps each test fully self-contained — no
  shared mock setup, no Agent — and matches the stateless philosophy
  of the Pipeline module itself.

  `poll_interval_ms/0` reads from the test process's :tmp Application
  config so each test can use whatever base interval it wants for
  backoff assertions.
  """

  use LongOrShort.DataCase, async: false

  alias LongOrShort.News
  alias LongOrShort.News.Dedup
  alias LongOrShort.News.Source.Pipeline

  # ── MockSource ─────────────────────────────────────────────────
  defmodule MockSource do
    @behaviour LongOrShort.News.Source

    @impl true
    def fetch_news(state) do
      fun = Map.fetch!(state, :fetch_news_fun)
      fun.(state)
    end

    @impl true
    def parse_response(raw) do
      # raw is expected to carry its own parse instruction so the test
      # can mix successful and erroring items in a single batch.
      case raw do
        %{__parse__: result} -> result
        _ -> {:error, :no_parse_instruction}
      end
    end

    @impl true
    def poll_interval_ms do
      Application.get_env(:long_or_short, :test_mock_poll_interval, 50)
    end
  end

  setup do
    Dedup.clear()
    Application.put_env(:long_or_short, :test_mock_poll_interval, 50)

    on_exit(fn ->
      Application.delete_env(:long_or_short, :test_mock_poll_interval)
    end)

    Phoenix.PubSub.subscribe(LongOrShort.PubSub, "news:articles")
  end

  defp valid_attrs(symbol, external_id) do
    %{
      source: :other,
      external_id: external_id,
      symbol: symbol,
      title: "Test headline",
      summary: "Test summary",
      published_at: DateTime.utc_now(),
      raw_category: "test",
      sentiment: :unknown
    }
  end

  defp raw_with_parse(parse_result) do
    %{__parse__: parse_result}
  end

  defp drain_poll_message do
    receive do
      :poll -> :ok
    after
      200 -> :timeout
    end
  end

  describe "run_poll/2 - success" do
    test "ingests articles, broadcasts, resets retry_count" do
      attrs = valid_attrs("BROAD1", "ext-broad-1")
      raw = raw_with_parse({:ok, [attrs]})

      state = %{
        retry_count: 3,
        fetch_news_fun: fn s -> {:ok, [raw], s} end
      }

      {:noreply, new_state} = Pipeline.run_poll(MockSource, state)

      # retry_count reset
      assert new_state.retry_count == 0

      # Article persisted
      assert {:ok, [article]} = News.list_articles(authorize?: false)
      assert article.title == "Test headline"

      # Broadcast received
      assert_receive {:new_article, %News.Article{title: "Test headline"}}, 100

      # Next poll scheduled
      assert drain_poll_message() == :ok
    end

    test "handles batch with multiple raw items" do
      raws = [
        raw_with_parse({:ok, [valid_attrs("AAA", "ext-a")]}),
        raw_with_parse({:ok, [valid_attrs("BBB", "ext-b")]}),
        raw_with_parse({:ok, [valid_attrs("CCC", "ext-c")]})
      ]

      state = %{
        retry_count: 0,
        fetch_news_fun: fn s -> {:ok, raws, s} end
      }

      {:noreply, _state} = Pipeline.run_poll(MockSource, state)

      {:ok, articles} = News.list_articles(authorize?: false)
      assert length(articles) == 3

      # 3 broadcasts
      assert_receive {:new_article, _}, 100
      assert_receive {:new_article, _}, 100
      assert_receive {:new_article, _}, 100
    end

    test "fans out one raw item to multiple tickers" do
      raw =
        raw_with_parse(
          {:ok,
           [
             valid_attrs("MULTI1", "ext-multi"),
             valid_attrs("MULTI2", "ext-multi"),
             valid_attrs("MULTI3", "ext-multi")
           ]}
        )

      state = %{
        retry_count: 0,
        fetch_news_fun: fn s -> {:ok, [raw], s} end
      }

      {:noreply, _state} = Pipeline.run_poll(MockSource, state)

      {:ok, articles} = News.list_articles(authorize?: false)
      assert length(articles) == 3
    end

    test "empty raw_items is valid (no error, retry stays 0)" do
      state = %{
        retry_count: 0,
        fetch_news_fun: fn s -> {:ok, [], s} end
      }

      {:noreply, new_state} = Pipeline.run_poll(MockSource, state)

      assert new_state.retry_count == 0
      assert {:ok, []} = News.list_articles(authorize?: false)
    end
  end

  describe "run_poll/2 — fetch error" do
    test "increments retry_count and uses Backoff for next interval" do
      state = %{
        retry_count: 0,
        fetch_news_fun: fn s -> {:error, :timeout, s} end
      }

      {:noreply, new_state} = Pipeline.run_poll(MockSource, state)

      assert new_state.retry_count == 1
      # Next poll scheduled (we don't assert exact timing — just that
      # a :poll message is queued)
      assert drain_poll_message() == :ok
    end

    test "successive errors keep growing retry_count" do
      state0 = %{
        retry_count: 0,
        fetch_news_fun: fn s -> {:error, :boom, s} end
      }

      {:noreply, state1} = Pipeline.run_poll(MockSource, state0)
      drain_poll_message()
      assert state1.retry_count == 1

      {:noreply, state2} = Pipeline.run_poll(MockSource, state1)
      drain_poll_message()
      assert state2.retry_count == 2

      {:noreply, state3} = Pipeline.run_poll(MockSource, state2)
      drain_poll_message()
      assert state3.retry_count == 3
    end

    test "successful poll after errors resets retry_count to 0" do
      attrs = valid_attrs("RECOVER", "ext-recover")
      raw = raw_with_parse({:ok, [attrs]})

      state = %{
        retry_count: 5,
        fetch_news_fun: fn s -> {:ok, [raw], s} end
      }

      {:noreply, new_state} = Pipeline.run_poll(MockSource, state)

      assert new_state.retry_count == 0
    end
  end

  describe "run_poll/2 — per-item resilience" do
    test "parse error on one item does not abort the batch" do
      raws = [
        raw_with_parse({:ok, [valid_attrs("OK1", "ext-ok-1")]}),
        raw_with_parse({:error, :malformed_xml}),
        raw_with_parse({:ok, [valid_attrs("OK2", "ext-ok-2")]})
      ]

      state = %{
        retry_count: 0,
        fetch_news_fun: fn s -> {:ok, raws, s} end
      }

      {:noreply, new_state} = Pipeline.run_poll(MockSource, state)

      # retry_count not bumped — fetch itself succeeded
      assert new_state.retry_count == 0

      # Two articles persisted (the third was unparseable)
      {:ok, articles} = News.list_articles(authorize?: false)
      assert length(articles) == 2
    end

    test "malformed attrs (missing required keys) skipped with warning" do
      raws = [
        raw_with_parse({:ok, [valid_attrs("GOOD", "ext-good")]}),
        raw_with_parse({:ok, [%{title: "missing source/external_id/symbol"}]})
      ]

      state = %{
        retry_count: 0,
        fetch_news_fun: fn s -> {:ok, raws, s} end
      }

      {:noreply, _state} = Pipeline.run_poll(MockSource, state)

      {:ok, articles} = News.list_articles(authorize?: false)
      assert length(articles) == 1
      assert hd(articles).title == "Test headline"
    end
  end

  # ── run_poll/2: dedup integration ──────────────────────────────

  describe "run_poll/2 — dedup integration" do
    test "second poll with same key skips ingest (deduped)" do
      attrs = valid_attrs("DEDUP", "ext-dedup")
      raw = raw_with_parse({:ok, [attrs]})

      state = %{
        retry_count: 0,
        fetch_news_fun: fn s -> {:ok, [raw], s} end
      }

      # First poll — article ingested
      {:noreply, _} = Pipeline.run_poll(MockSource, state)
      drain_poll_message()
      assert_receive {:new_article, _}, 100
      {:ok, [_article]} = News.list_articles(authorize?: false)

      # Second poll with same raw — Dedup blocks
      {:noreply, _} = Pipeline.run_poll(MockSource, state)
      drain_poll_message()
      refute_receive {:new_article, _}, 100

      # Still only one article in DB
      {:ok, articles} = News.list_articles(authorize?: false)
      assert length(articles) == 1
    end
  end

  # ── init/2 ──────────────────────────────────────────────────────

  describe "init/2" do
    test "merges initial custom state with retry_count: 0" do
      {:ok, state} = Pipeline.init(MockSource, state: %{counter: 0, foo: :bar})

      assert state.retry_count == 0
      assert state.counter == 0
      assert state.foo == :bar
    end

    test "schedules first poll immediately" do
      {:ok, _state} = Pipeline.init(MockSource)
      assert drain_poll_message() == :ok
    end

    test "Pipeline-reserved keys override custom state on conflict" do
      # Even if caller tries to seed retry_count, Pipeline overrides to 0
      {:ok, state} = Pipeline.init(MockSource, state: %{retry_count: 99})

      assert state.retry_count == 0
    end
  end
end
