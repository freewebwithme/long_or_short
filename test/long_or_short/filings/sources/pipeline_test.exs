defmodule LongOrShort.Filings.Sources.PipelineTest do
  @moduledoc """
  Tests for the filings polling pipeline.

  Strategy mirrors `News.Sources.PipelineTest` — a single MockSource
  module whose `fetch_filings/1` looks up its behavior from the
  state map passed in. This keeps each test self-contained and
  matches the stateless philosophy of the Pipeline module.

  The ingest sink is exercised through the `:ingest_fun` opt: tests
  pass a function that sends parsed attrs back to the test process
  so we can assert dispatch happened (and with what payload).
  """

  use LongOrShort.DataCase, async: false
  @moduletag :capture_log

  alias LongOrShort.Filings.Sources.Pipeline

  # ── MockSource ─────────────────────────────────────────────────
  defmodule MockSource do
    @behaviour LongOrShort.Filings.Source

    @impl true
    def fetch_filings(state) do
      fun = Map.fetch!(state, :fetch_filings_fun)
      fun.(state)
    end

    @impl true
    def parse_response(raw) do
      case raw do
        %{__parse__: result} -> result
        _ -> {:error, :no_parse_instruction}
      end
    end

    @impl true
    def poll_interval_ms do
      Application.get_env(:long_or_short, :test_mock_poll_interval, 50)
    end

    @impl true
    # Reuses an enum value already accepted by SourceState. The
    # production SecEdgar feeder also uses :sec_filings, but tests
    # are async: false and run serially, so cursor collisions are
    # not a concern.
    def source_name, do: :sec_filings
  end

  setup do
    Application.put_env(:long_or_short, :test_mock_poll_interval, 50)

    on_exit(fn ->
      Application.delete_env(:long_or_short, :test_mock_poll_interval)
      Application.delete_env(:long_or_short, :filings_ingest_fun)
    end)

    :ok
  end

  # ── helpers ────────────────────────────────────────────────────

  defp valid_attrs(symbol, external_id) do
    %{
      source: :sec_edgar,
      filing_type: :_8k,
      filing_subtype: "Item 3.02",
      external_id: external_id,
      symbol: symbol,
      filer_cik: "0001234567",
      filed_at: DateTime.utc_now(),
      url: "https://example.com/filing/" <> external_id
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

  defp capturing_ingest_fun do
    parent = self()
    fn attrs -> send(parent, {:ingested, attrs}); {:ok, :captured} end
  end

  # ── run_poll/2 — success ────────────────────────────────────────

  describe "run_poll/2 — success" do
    test "dispatches to ingest_fun and resets retry_count" do
      attrs = valid_attrs("BROAD1", "ext-broad-1")
      raw = raw_with_parse({:ok, [attrs]})

      state = %{
        retry_count: 3,
        ingest_fun: capturing_ingest_fun(),
        fetch_filings_fun: fn s -> {:ok, [raw], s} end
      }

      {:noreply, new_state} = Pipeline.run_poll(MockSource, state)

      assert new_state.retry_count == 0
      assert_receive {:ingested, ^attrs}, 100
      assert drain_poll_message() == :ok
    end

    test "handles a batch of multiple raw items" do
      raws = [
        raw_with_parse({:ok, [valid_attrs("AAA", "ext-a")]}),
        raw_with_parse({:ok, [valid_attrs("BBB", "ext-b")]}),
        raw_with_parse({:ok, [valid_attrs("CCC", "ext-c")]})
      ]

      state = %{
        retry_count: 0,
        ingest_fun: capturing_ingest_fun(),
        fetch_filings_fun: fn s -> {:ok, raws, s} end
      }

      {:noreply, _state} = Pipeline.run_poll(MockSource, state)

      assert_receive {:ingested, %{symbol: "AAA"}}, 100
      assert_receive {:ingested, %{symbol: "BBB"}}, 100
      assert_receive {:ingested, %{symbol: "CCC"}}, 100
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
        ingest_fun: capturing_ingest_fun(),
        fetch_filings_fun: fn s -> {:ok, [raw], s} end
      }

      {:noreply, _state} = Pipeline.run_poll(MockSource, state)

      assert_receive {:ingested, %{symbol: "MULTI1"}}, 100
      assert_receive {:ingested, %{symbol: "MULTI2"}}, 100
      assert_receive {:ingested, %{symbol: "MULTI3"}}, 100
    end

    test "empty raw_items is valid (no error, retry stays 0)" do
      state = %{
        retry_count: 0,
        ingest_fun: capturing_ingest_fun(),
        fetch_filings_fun: fn s -> {:ok, [], s} end
      }

      {:noreply, new_state} = Pipeline.run_poll(MockSource, state)

      assert new_state.retry_count == 0
      refute_receive {:ingested, _}, 50
    end
  end

  # ── run_poll/2 — fetch error ────────────────────────────────────

  describe "run_poll/2 — fetch error" do
    test "increments retry_count and schedules next poll via Backoff" do
      state = %{
        retry_count: 0,
        ingest_fun: capturing_ingest_fun(),
        fetch_filings_fun: fn s -> {:error, :timeout, s} end
      }

      {:noreply, new_state} = Pipeline.run_poll(MockSource, state)

      assert new_state.retry_count == 1
      assert drain_poll_message() == :ok
    end

    test "successive errors keep growing retry_count" do
      state0 = %{
        retry_count: 0,
        ingest_fun: capturing_ingest_fun(),
        fetch_filings_fun: fn s -> {:error, :boom, s} end
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
        ingest_fun: capturing_ingest_fun(),
        fetch_filings_fun: fn s -> {:ok, [raw], s} end
      }

      {:noreply, new_state} = Pipeline.run_poll(MockSource, state)

      assert new_state.retry_count == 0
    end
  end

  # ── run_poll/2 — per-item resilience ────────────────────────────

  describe "run_poll/2 — per-item resilience" do
    test "parse error on one item does not abort the batch" do
      raws = [
        raw_with_parse({:ok, [valid_attrs("OK1", "ext-ok-1")]}),
        raw_with_parse({:error, :malformed_xml}),
        raw_with_parse({:ok, [valid_attrs("OK2", "ext-ok-2")]})
      ]

      state = %{
        retry_count: 0,
        ingest_fun: capturing_ingest_fun(),
        fetch_filings_fun: fn s -> {:ok, raws, s} end
      }

      {:noreply, new_state} = Pipeline.run_poll(MockSource, state)

      # retry_count not bumped — fetch itself succeeded
      assert new_state.retry_count == 0

      # Two filings dispatched (the third was unparseable)
      assert_receive {:ingested, %{symbol: "OK1"}}, 100
      assert_receive {:ingested, %{symbol: "OK2"}}, 100
    end

    test "malformed attrs (missing required keys) skipped with warning" do
      raws = [
        raw_with_parse({:ok, [valid_attrs("GOOD", "ext-good")]}),
        raw_with_parse({:ok, [%{title: "missing source/filing_type/external_id/symbol"}]})
      ]

      state = %{
        retry_count: 0,
        ingest_fun: capturing_ingest_fun(),
        fetch_filings_fun: fn s -> {:ok, raws, s} end
      }

      {:noreply, _state} = Pipeline.run_poll(MockSource, state)

      assert_receive {:ingested, %{symbol: "GOOD"}}, 100
      refute_receive {:ingested, _}, 50
    end

    test "ingest_fun returning {:error, _} does not crash the batch" do
      attrs1 = valid_attrs("FIRST", "ext-1")
      attrs2 = valid_attrs("SECOND", "ext-2")
      raws = [raw_with_parse({:ok, [attrs1]}), raw_with_parse({:ok, [attrs2]})]

      parent = self()

      ingest_fun = fn attrs ->
        send(parent, {:tried, attrs})
        if attrs.symbol == "FIRST", do: {:error, :db_down}, else: {:ok, :persisted}
      end

      state = %{
        retry_count: 0,
        ingest_fun: ingest_fun,
        fetch_filings_fun: fn s -> {:ok, raws, s} end
      }

      {:noreply, _state} = Pipeline.run_poll(MockSource, state)

      assert_receive {:tried, %{symbol: "FIRST"}}, 100
      assert_receive {:tried, %{symbol: "SECOND"}}, 100
    end
  end

  # ── ingest_fun resolution ───────────────────────────────────────

  describe "ingest_fun resolution" do
    test "state ingest_fun takes precedence over app env" do
      parent = self()

      Application.put_env(:long_or_short, :filings_ingest_fun, fn attrs ->
        send(parent, {:from_env, attrs})
        {:ok, :env}
      end)

      attrs = valid_attrs("RES", "ext-res")
      raw = raw_with_parse({:ok, [attrs]})

      state = %{
        retry_count: 0,
        ingest_fun: fn a ->
          send(parent, {:from_state, a})
          {:ok, :state}
        end,
        fetch_filings_fun: fn s -> {:ok, [raw], s} end
      }

      {:noreply, _state} = Pipeline.run_poll(MockSource, state)

      assert_receive {:from_state, ^attrs}, 100
      refute_receive {:from_env, _}, 50
    end

    test "app env ingest_fun is used when state has none" do
      parent = self()

      Application.put_env(:long_or_short, :filings_ingest_fun, fn attrs ->
        send(parent, {:from_env, attrs})
        {:ok, :env}
      end)

      attrs = valid_attrs("ENV", "ext-env")
      raw = raw_with_parse({:ok, [attrs]})

      state = %{
        retry_count: 0,
        fetch_filings_fun: fn s -> {:ok, [raw], s} end
      }

      {:noreply, _state} = Pipeline.run_poll(MockSource, state)

      assert_receive {:from_env, ^attrs}, 100
    end

    test "falls back to log_and_drop default sink when nothing is configured" do
      attrs = valid_attrs("DEFAULT", "ext-default")
      raw = raw_with_parse({:ok, [attrs]})

      state = %{
        retry_count: 0,
        fetch_filings_fun: fn s -> {:ok, [raw], s} end
      }

      # capture_log via @moduletag — log_and_drop emits an info line
      # and returns {:ok, :dropped}, so retry_count stays 0.
      {:noreply, new_state} = Pipeline.run_poll(MockSource, state)
      assert new_state.retry_count == 0
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

    test "schedules first poll immediately when SourceState has no cursor" do
      {:ok, _state} = Pipeline.init(MockSource)
      assert drain_poll_message() == :ok
    end

    test "Pipeline-reserved keys override custom state on conflict" do
      {:ok, state} = Pipeline.init(MockSource, state: %{retry_count: 99})
      assert state.retry_count == 0
    end

    test "stores ingest_fun in state when passed as opt" do
      fun = fn _attrs -> {:ok, :captured} end
      {:ok, state} = Pipeline.init(MockSource, ingest_fun: fun)

      assert state.ingest_fun == fun
    end
  end
end
