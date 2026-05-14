defmodule LongOrShort.Filings.Workers.FilingAnalysisWorkerTest do
  @moduledoc """
  Tests for the Tier 1 universe-scoped cron worker (LON-135).

  Verifies:

    * universe scoping — only filings whose ticker is in the active
      small-cap universe get analyzed (replaces the pre-LON-135
      watchlist scoping path).
    * Tier 1 only — rows land with `extracted_keywords` populated
      and `dilution_severity = nil`; Tier 2 stays an on-demand path.
    * cost telemetry — per-run + today-running-total token + cost
      measurements emitted on every non-empty batch.
  """

  use LongOrShort.DataCase, async: false
  use Oban.Testing, repo: LongOrShort.Repo

  require Ash.Query

  import LongOrShort.FilingsFixtures

  alias LongOrShort.AI.MockProvider
  alias LongOrShort.Filings
  alias LongOrShort.Filings.Workers.FilingAnalysisWorker
  alias LongOrShort.Tickers
  alias LongOrShort.Tickers.SmallCapUniverseMembership

  setup do
    MockProvider.reset()

    original_models = Application.fetch_env!(:long_or_short, :filing_extraction_models)

    Application.put_env(
      :long_or_short,
      :filing_extraction_models,
      Map.put(original_models, MockProvider, %{cheap: "mock-cheap", complex: "mock-complex"})
    )

    # Remove rate-limit pause for fast test runs. Production still uses
    # the 200ms default via @default_per_item_pause_ms.
    Application.put_env(:long_or_short, :filing_analysis_worker_pause_ms, 0)

    on_exit(fn ->
      Application.put_env(:long_or_short, :filing_extraction_models, original_models)
      Application.delete_env(:long_or_short, :filing_analysis_worker_pause_ms)
    end)

    :ok
  end

  # ── Helpers ────────────────────────────────────────────────────

  defp tool_response(usage \\ %{input_tokens: 1_000, output_tokens: 200}) do
    {:ok,
     %{
       tool_calls: [
         %{
           name: "record_filing_extraction",
           input: %{
             "dilution_type" => "atm",
             "pricing_method" => "vwap_based",
             "summary" => "Sample"
           }
         }
       ],
       text: nil,
       usage: usage
     }}
  end

  defp setup_filing_with_raw(symbol, filing_type \\ :s3) do
    filing = build_filing(%{filing_type: filing_type, symbol: symbol})
    _raw = build_filing_raw(filing)
    filing
  end

  defp add_to_universe(ticker_id) do
    {:ok, _} =
      Tickers.upsert_small_cap_membership(
        %{ticker_id: ticker_id, source: :iwm},
        authorize?: false
      )

    :ok
  end

  defp attach_telemetry do
    handler_id = "filing-analysis-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:long_or_short, :filing_analysis_worker, :complete],
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, :complete, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  # ── Universe scoping ───────────────────────────────────────────

  describe "perform/1 — universe scoping" do
    test "analyzes filings whose ticker is in the small-cap universe; ignores others" do
      MockProvider.stub(fn _, _, _ -> tool_response() end)

      in_universe = setup_filing_with_raw("INUNI")
      not_in_universe = setup_filing_with_raw("NOTINUNI")

      add_to_universe(in_universe.ticker_id)

      assert :ok = perform_job(FilingAnalysisWorker, %{})

      assert {:ok, %{id: _}} =
               Filings.get_filing_analysis_by_filing(in_universe.id, authorize?: false)

      assert {:ok, nil} =
               Filings.get_filing_analysis_by_filing(not_in_universe.id, authorize?: false)
    end

    test "returns :ok with no work when the universe is empty" do
      _filing = setup_filing_with_raw("LONELY")

      assert :ok = perform_job(FilingAnalysisWorker, %{})
    end

    test "ignores membership rows whose is_active is false" do
      MockProvider.stub(fn _, _, _ -> tool_response() end)

      filing = setup_filing_with_raw("INACTIVE")
      add_to_universe(filing.ticker_id)

      SmallCapUniverseMembership
      |> Ash.Query.filter(ticker_id == ^filing.ticker_id)
      |> Ash.bulk_update!(:deactivate, %{}, authorize?: false)

      assert :ok = perform_job(FilingAnalysisWorker, %{})

      assert {:ok, nil} =
               Filings.get_filing_analysis_by_filing(filing.id, authorize?: false)
    end
  end

  # ── Tier 1 row shape ───────────────────────────────────────────

  describe "perform/1 — Tier 1 only" do
    test "creates rows with extracted_keywords populated and severity nil" do
      MockProvider.stub(fn _, _, _ -> tool_response() end)

      filing = setup_filing_with_raw("TIER1NEW")
      add_to_universe(filing.ticker_id)

      assert :ok = perform_job(FilingAnalysisWorker, %{})

      {:ok, analysis} =
        Filings.get_filing_analysis_by_filing(filing.id, authorize?: false)

      assert analysis != nil
      assert analysis.extraction_quality == :high
      assert analysis.dilution_severity == nil
      assert analysis.matched_rules == []
      assert is_map(analysis.extracted_keywords)
    end

    test "skips filings that already have an analysis row" do
      MockProvider.stub(fn _, _, _ -> tool_response() end)

      filing = setup_filing_with_raw("ALREADY")
      add_to_universe(filing.ticker_id)
      _ = build_filing_analysis(filing, %{summary: "pre-existing analysis"})

      assert :ok = perform_job(FilingAnalysisWorker, %{})

      {:ok, analysis} =
        Filings.get_filing_analysis_by_filing(filing.id, authorize?: false)

      assert analysis.summary == "pre-existing analysis"
    end

    test "skips filings that have no FilingRaw body yet" do
      MockProvider.stub(fn _, _, _ -> tool_response() end)

      filing = build_filing(%{filing_type: :s3, symbol: "NOBODY"})
      add_to_universe(filing.ticker_id)

      assert :ok = perform_job(FilingAnalysisWorker, %{})

      assert {:ok, nil} =
               Filings.get_filing_analysis_by_filing(filing.id, authorize?: false)
    end
  end

  # ── Cost telemetry ─────────────────────────────────────────────

  describe "perform/1 — cost telemetry" do
    test "emits :complete with token + cost measurements" do
      attach_telemetry()

      MockProvider.stub(fn _, _, _ ->
        tool_response(%{input_tokens: 1_000_000, output_tokens: 200_000})
      end)

      filing = setup_filing_with_raw("COSTONE")
      add_to_universe(filing.ticker_id)

      assert :ok = perform_job(FilingAnalysisWorker, %{})

      {:ok, analysis} =
        Filings.get_filing_analysis_by_filing(filing.id, authorize?: false)

      assert_receive {:telemetry, :complete, measurements, metadata}

      assert measurements.ok == 1
      assert measurements.error == 0
      assert measurements.skipped == 0
      assert measurements.total == 1
      assert measurements.input_tokens == 1_000_000
      assert measurements.output_tokens == 200_000
      # Cost is non-zero given non-zero tokens + a known mock price.
      # Exact value depends on which model the Router picked, so we
      # avoid pinning the cent count.
      assert measurements.cost_cents > 0
      assert measurements.today_cost_cents == measurements.cost_cents

      assert metadata.tier == 1
      assert metadata.model == analysis.model
    end

    test "today_cost_cents accumulates across runs on the same day" do
      attach_telemetry()

      MockProvider.stub(fn _, _, _ ->
        tool_response(%{input_tokens: 1_000_000, output_tokens: 0})
      end)

      filing_a = setup_filing_with_raw("DAYA")
      add_to_universe(filing_a.ticker_id)
      assert :ok = perform_job(FilingAnalysisWorker, %{})

      assert_receive {:telemetry, :complete, m1, _}
      per_call_cost = m1.cost_cents
      assert per_call_cost > 0
      assert m1.today_cost_cents == per_call_cost

      filing_b = setup_filing_with_raw("DAYB")
      add_to_universe(filing_b.ticker_id)
      assert :ok = perform_job(FilingAnalysisWorker, %{})

      assert_receive {:telemetry, :complete, m2, _}
      # Same filing_type, same model, same tokens → same per-call cost.
      assert m2.cost_cents == per_call_cost
      assert m2.today_cost_cents == per_call_cost * 2
    end

    test "does not emit when there is no work" do
      attach_telemetry()

      # No universe → early return before run_batch fires telemetry.
      _ = setup_filing_with_raw("NOTELE")

      assert :ok = perform_job(FilingAnalysisWorker, %{})

      refute_receive {:telemetry, :complete, _, _}, 100
    end
  end
end
