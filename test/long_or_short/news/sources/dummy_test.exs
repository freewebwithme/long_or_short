defmodule LongOrShort.News.Sources.DummyTest do
  @moduledoc """
  Tests for the Dummy news source.

  Pure callback tests (parse_response/1, fetch_news/1) call the
  module's functions directly without starting a GenServer — fast,
  isolated, no DB or PubSub side effects.

  The integration test brings up Dedup and Dummy as real
  GenServers and verifies that a real Article lands in the DB and
  a real broadcast reaches the test process.
  """

  use LongOrShort.DataCase, async: false

  alias LongOrShort.News
  alias LongOrShort.News.Article
  alias LongOrShort.News.Dedup
  alias LongOrShort.News.Sources.Dummy

  setup do
    Dedup.clear()
    :ok
  end

  describe "parse_response/1" do
    test "produces an attrs map with all required keys" do
      raw = %{
        external_id: "dummy-42",
        symbol: "BTBD",
        title: "Test headline",
        summary: "Test summary"
      }

      assert {:ok, [attrs]} = Dummy.parse_response(raw)

      assert attrs.source == :other
      assert attrs.external_id == "dummy-42"
      assert attrs.symbol == "BTBD"
      assert attrs.title == "Test headline"
      assert attrs.summary == "Test summary"
      assert attrs.raw_category == "General"
      assert attrs.sentiment == :unknown
      assert %DateTime{} = attrs.published_at
    end

    test "returns a list (single-element) for the per-ticker fan-out contract" do
      raw = %{
        external_id: "dummy-0",
        symbol: "AAPL",
        title: "x",
        summary: "y"
      }

      assert {:ok, attrs_list} = Dummy.parse_response(raw)
      assert is_list(attrs_list)
      assert length(attrs_list) == 1
    end
  end

  describe "fetch_news/1" do
    test "increments counter and returns one raw item per call" do
      {:ok, [raw0], state1} = Dummy.fetch_news(%{})
      assert raw0.external_id == "dummy-0"
      assert state1.counter == 1

      {:ok, [raw1], state2} = Dummy.fetch_news(state1)
      assert raw1.external_id == "dummy-1"
      assert state2.counter == 2

      {:ok, [raw2], state3} = Dummy.fetch_news(state2)
      assert raw2.external_id == "dummy-2"
      assert state3.counter == 3
    end

    test "cycles through 5 samples with distinct symbols" do
      symbols =
        Enum.reduce(0..4, {[], %{}}, fn _, {acc, state} ->
          {:ok, [raw], new_state} = Dummy.fetch_news(state)
          {[raw.symbol | acc], new_state}
        end)
        |> elem(0)
        |> Enum.reverse()

      assert symbols == ["BTBD", "AAPL", "TSLA", "NVDA", "AMD"]
    end

    test "wraps around to the first sample after one full cycle" do
      # advance to counter=5 (one full cycle done)
      state =
        Enum.reduce(1..5, %{}, fn _, st ->
          {:ok, _, new_st} = Dummy.fetch_news(st)
          new_st
        end)

      assert state.counter == 5

      # 6th call: counter=5, rem(5,5)=0 → BTBD again, but with different external_id
      {:ok, [raw], _} = Dummy.fetch_news(state)
      assert raw.symbol == "BTBD"
      assert raw.external_id == "dummy-5"
    end

    test "preserves additional state keys (does not overwrite)" do
      state = %{counter: 0, custom_key: :custom_value}

      {:ok, _, new_state} = Dummy.fetch_news(state)

      assert new_state.counter == 1
      assert new_state.custom_key == :custom_value
    end
  end

  # ── poll_interval_ms/0 ─────────────────────────────────────────

  describe "poll_interval_ms/0" do
    test "returns 3 seconds" do
      assert Dummy.poll_interval_ms() == 3_000
    end
  end

  # ── Integration ────────────────────────────────────────────────

  describe "integration (real GenServer)" do
    test "starting Dummy ingests articles and broadcasts" do
      Phoenix.PubSub.subscribe(LongOrShort.PubSub, "news:articles")

      start_supervised!(Dummy)

      # Pipeline.init schedules first poll immediately, so within a
      # short window the broadcast should arrive
      assert_receive {:new_article, %Article{source: :other} = article}, 500

      assert article.title in [
               "BTBD announces new strategic partnership",
               "Apple beats Q2 earnings expectations",
               "Tesla quarterly deliveries up 15% YoY",
               "Nvidia unveils next-generation AI chip",
               "AMD partners with major cloud provider"
             ]

      # And it should be persisted
      {:ok, articles} = News.list_articles(authorize?: false)
      assert length(articles) >= 1
    end
  end
end
