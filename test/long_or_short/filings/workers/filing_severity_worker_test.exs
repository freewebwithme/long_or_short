defmodule LongOrShort.Filings.Workers.FilingSeverityWorkerTest do
  @moduledoc """
  Tests for the Tier 2 background sweep cron worker (LON-136).

  Verifies:

    * Tier-1-only rows (`extraction_quality = :high AND severity IS NULL`)
      get promoted to fully scored
    * Already-scored rows + `:rejected` quality rows are skipped (action
      filter excludes them)
    * Empty pending → no-op + no telemetry
    * Telemetry shape on completion
    * `score_severity/1` broadcast propagates through the worker path
  """

  use LongOrShort.DataCase, async: false
  use Oban.Testing, repo: LongOrShort.Repo

  import LongOrShort.FilingsFixtures

  alias LongOrShort.Filings
  alias LongOrShort.Filings.{Events, FilingAnalysis}
  alias LongOrShort.Filings.Workers.FilingSeverityWorker

  # ── Helpers ────────────────────────────────────────────────────

  defp tier_1_only(filing, overrides \\ %{}) do
    base = %{
      dilution_severity: nil,
      matched_rules: [],
      severity_reason: nil
    }

    build_filing_analysis(filing, Map.merge(base, overrides))
  end

  defp attach_telemetry do
    handler_id = "filing-severity-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:long_or_short, :filing_severity_worker, :complete],
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, :complete, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  # ── Happy path ─────────────────────────────────────────────────

  describe "perform/1 — promotes Tier 1 → Tier 2" do
    test "fills severity on a single pending row" do
      filing = build_filing(%{filing_type: :s3, symbol: "PROMO1"})
      _row = tier_1_only(filing)

      assert :ok = perform_job(FilingSeverityWorker, %{})

      {:ok, refreshed} =
        Filings.get_filing_analysis_by_filing(filing.id, authorize?: false)

      assert refreshed != nil
      assert refreshed.dilution_severity != nil
      assert refreshed.extraction_quality == :high
    end

    test "processes multiple pending rows in one cycle" do
      filing_a = build_filing(%{filing_type: :s3, symbol: "MULTIA"})
      filing_b = build_filing(%{filing_type: :s3, symbol: "MULTIB"})
      tier_1_only(filing_a)
      tier_1_only(filing_b)

      assert :ok = perform_job(FilingSeverityWorker, %{})

      {:ok, a} = Filings.get_filing_analysis_by_filing(filing_a.id, authorize?: false)
      {:ok, b} = Filings.get_filing_analysis_by_filing(filing_b.id, authorize?: false)

      assert a.dilution_severity != nil
      assert b.dilution_severity != nil
    end
  end

  # ── Idempotency ────────────────────────────────────────────────

  describe "perform/1 — idempotency" do
    test "leaves already-scored rows untouched" do
      filing = build_filing(%{filing_type: :s3, symbol: "DONE"})
      _row = build_filing_analysis(filing, %{dilution_severity: :critical})

      assert :ok = perform_job(FilingSeverityWorker, %{})

      {:ok, refreshed} =
        Filings.get_filing_analysis_by_filing(filing.id, authorize?: false)

      assert refreshed.dilution_severity == :critical
    end

    test "leaves :rejected quality rows untouched (filter excludes them)" do
      filing = build_filing(%{filing_type: :s3, symbol: "REJ"})

      _row =
        tier_1_only(filing, %{
          extraction_quality: :rejected,
          rejected_reason: "extractor:no_tool_call"
        })

      assert :ok = perform_job(FilingSeverityWorker, %{})

      {:ok, refreshed} =
        Filings.get_filing_analysis_by_filing(filing.id, authorize?: false)

      assert refreshed.dilution_severity == nil
      assert refreshed.extraction_quality == :rejected
    end
  end

  # ── Empty pending ──────────────────────────────────────────────

  describe "perform/1 — empty" do
    test "returns :ok when there is nothing to score" do
      assert :ok = perform_job(FilingSeverityWorker, %{})
    end

    test "does not emit telemetry when there is no work" do
      attach_telemetry()

      assert :ok = perform_job(FilingSeverityWorker, %{})

      refute_receive {:telemetry, :complete, _, _}, 100
    end
  end

  # ── Telemetry ──────────────────────────────────────────────────

  describe "perform/1 — telemetry" do
    test "emits :complete with ok/error/total counts" do
      attach_telemetry()

      filing = build_filing(%{filing_type: :s3, symbol: "TELE"})
      tier_1_only(filing)

      assert :ok = perform_job(FilingSeverityWorker, %{})

      assert_receive {:telemetry, :complete, measurements, _metadata}
      assert measurements.ok == 1
      assert measurements.error == 0
      assert measurements.total == 1
    end
  end

  # ── PubSub broadcast ───────────────────────────────────────────

  describe "perform/1 — PubSub" do
    test "score_severity broadcasts :new_filing_analysis for each promoted row" do
      :ok = Events.subscribe()

      filing = build_filing(%{filing_type: :s3, symbol: "BCAST"})
      tier_1_only(filing)

      assert :ok = perform_job(FilingSeverityWorker, %{})

      assert_receive {:new_filing_analysis, %FilingAnalysis{} = received}, 500
      assert received.filing_id == filing.id
      assert received.dilution_severity != nil
    end
  end
end
