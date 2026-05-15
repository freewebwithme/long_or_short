defmodule LongOrShort.Filings.Workers.IngestHealthReporterTest do
  @moduledoc """
  Tests for the daily Tier 1 ingest health reporter (LON-161).

  Verifies that:

    * aggregation over `filing_analyses` rows correctly partitions
      by `extraction_quality` and computes a rejection rate
    * the top-N rejected-reason ranking honors frequency order
      and handles tuple-shaped reasons (e.g. `{:rate_limited, "20"}`)
    * `IngestHealth.read_and_reset_cik_drops/0` is called and the
      drained counts appear in the telemetry payload
    * a `:daily_summary` telemetry event is emitted with both
      analysis stats and CIK-drop counts
  """

  use LongOrShort.DataCase, async: false
  use Oban.Testing, repo: LongOrShort.Repo

  import LongOrShort.FilingsFixtures

  alias LongOrShort.Filings.IngestHealth
  alias LongOrShort.Filings.Workers.IngestHealthReporter

  setup do
    IngestHealth.init()
    IngestHealth.attach_telemetry_handler()
    _ = IngestHealth.read_and_reset_cik_drops()
    :ok
  end

  defp attach_summary_telemetry do
    handler_id = "ingest-health-summary-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:long_or_short, :ingest_health, :daily_summary],
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, :daily_summary, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  defp seed_analysis(filing, overrides) do
    build_filing_analysis(filing, overrides)
  end

  describe "perform/1 — analysis aggregation" do
    test "counts by quality and computes a non-zero rejection rate" do
      attach_summary_telemetry()

      filing_a = build_filing(%{symbol: "AGGA"})
      filing_b = build_filing(%{symbol: "AGGB"})
      filing_c = build_filing(%{symbol: "AGGC"})
      filing_d = build_filing(%{symbol: "AGGD"})

      seed_analysis(filing_a, %{extraction_quality: :high})
      seed_analysis(filing_b, %{extraction_quality: :high})
      seed_analysis(filing_c, %{extraction_quality: :high})
      seed_analysis(filing_d, %{extraction_quality: :rejected, rejected_reason: "validation_failed"})

      assert :ok = perform_job(IngestHealthReporter, %{})

      assert_receive {:telemetry, :daily_summary, m, _meta}
      assert m.analyses_total == 4
      assert m.analyses_high == 3
      assert m.analyses_rejected == 1
      assert m.rejection_rate_pct == 25.0
    end

    test "rejection_rate_pct is 0.0 when there are no analyses" do
      attach_summary_telemetry()

      assert :ok = perform_job(IngestHealthReporter, %{})

      assert_receive {:telemetry, :daily_summary, m, _meta}
      assert m.analyses_total == 0
      assert m.rejection_rate_pct == 0.0
    end
  end

  describe "perform/1 — top rejected reasons" do
    test "ranks reasons by frequency and surfaces them in metadata" do
      attach_summary_telemetry()

      filings = for s <- ~w(R1 R2 R3 R4 R5), do: build_filing(%{symbol: s})
      [f1, f2, f3, f4, f5] = filings

      seed_analysis(f1, %{extraction_quality: :rejected, rejected_reason: "validation_failed"})
      seed_analysis(f2, %{extraction_quality: :rejected, rejected_reason: "validation_failed"})
      seed_analysis(f3, %{extraction_quality: :rejected, rejected_reason: "validation_failed"})
      seed_analysis(f4, %{extraction_quality: :rejected, rejected_reason: "llm_error"})
      seed_analysis(f5, %{extraction_quality: :rejected, rejected_reason: "llm_error"})

      assert :ok = perform_job(IngestHealthReporter, %{})

      assert_receive {:telemetry, :daily_summary, _m, meta}

      assert [{first_reason, 3}, {second_reason, 2}] = meta.top_rejected_reasons
      assert first_reason =~ "validation_failed"
      assert second_reason =~ "llm_error"
    end

    test "handles non-string rejected_reason via inspect/1" do
      attach_summary_telemetry()

      f = build_filing(%{symbol: "TUP"})
      seed_analysis(f, %{extraction_quality: :rejected, rejected_reason: "{:rate_limited, \"20\"}"})

      assert :ok = perform_job(IngestHealthReporter, %{})

      assert_receive {:telemetry, :daily_summary, _m, meta}
      assert [{reason_key, 1}] = meta.top_rejected_reasons
      assert is_binary(reason_key)
    end
  end

  describe "perform/1 — CIK drop counters" do
    test "drains the in-memory counter and surfaces both source values" do
      attach_summary_telemetry()

      event = IngestHealth.cik_drop_event_name()
      :telemetry.execute(event, %{}, %{source: :filings, cik: "0001"})
      :telemetry.execute(event, %{}, %{source: :filings, cik: "0002"})
      :telemetry.execute(event, %{}, %{source: :news, cik: "0003"})

      assert :ok = perform_job(IngestHealthReporter, %{})

      assert_receive {:telemetry, :daily_summary, m, _meta}
      assert m.cik_drops_filings == 2
      assert m.cik_drops_news == 1

      # Drained: a second run sees zero.
      assert %{filings: 0, news: 0} = IngestHealth.peek_cik_drops()
    end
  end
end
