defmodule LongOrShort.Filings.IngestHealthTest do
  @moduledoc """
  Tests for the ephemeral CIK-drop counter and its telemetry handler
  (LON-161). Verifies:

    * counter increments via the `[:long_or_short, :filings, :cik_drop]`
      telemetry event
    * `read_and_reset_cik_drops/0` returns the current values and
      atomically zeroes them
    * unknown `:source` metadata is ignored (defense against future
      callers that emit the event without classifying the source)
  """

  use ExUnit.Case, async: false

  alias LongOrShort.Filings.IngestHealth

  setup do
    # The Application.start hook already calls init + attach, but
    # tests still drain the counter so each test starts at zero.
    IngestHealth.init()
    IngestHealth.attach_telemetry_handler()
    _ = IngestHealth.read_and_reset_cik_drops()
    :ok
  end

  describe "telemetry → counter" do
    test "increments per source on each cik_drop event" do
      event = IngestHealth.cik_drop_event_name()

      :telemetry.execute(event, %{}, %{source: :filings, cik: "0000001"})
      :telemetry.execute(event, %{}, %{source: :filings, cik: "0000002"})
      :telemetry.execute(event, %{}, %{source: :news, cik: "0000003"})

      assert %{filings: 2, news: 1} = IngestHealth.peek_cik_drops()
    end

    test "ignores events whose source is neither :filings nor :news" do
      event = IngestHealth.cik_drop_event_name()

      :telemetry.execute(event, %{}, %{source: :unknown, cik: "X"})
      :telemetry.execute(event, %{}, %{cik: "Y"})

      assert %{filings: 0, news: 0} = IngestHealth.peek_cik_drops()
    end
  end

  describe "read_and_reset_cik_drops/0" do
    test "returns current values and zeroes them atomically" do
      event = IngestHealth.cik_drop_event_name()

      :telemetry.execute(event, %{}, %{source: :filings, cik: "A"})
      :telemetry.execute(event, %{}, %{source: :filings, cik: "B"})
      :telemetry.execute(event, %{}, %{source: :news, cik: "C"})

      assert %{filings: 2, news: 1} = IngestHealth.read_and_reset_cik_drops()
      assert %{filings: 0, news: 0} = IngestHealth.peek_cik_drops()
    end

    test "returns zeroes when no drops have been recorded" do
      assert %{filings: 0, news: 0} = IngestHealth.read_and_reset_cik_drops()
    end

    test "increments after a reset rebuild the keys from default" do
      event = IngestHealth.cik_drop_event_name()

      :telemetry.execute(event, %{}, %{source: :filings, cik: "X"})
      assert %{filings: 1} = IngestHealth.read_and_reset_cik_drops()

      :telemetry.execute(event, %{}, %{source: :filings, cik: "Y"})
      assert %{filings: 1} = IngestHealth.peek_cik_drops()
    end
  end
end
