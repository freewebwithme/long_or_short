defmodule LongOrShort.Filings.Workers.FilingAnalysisBackfillWorkerTest do
  @moduledoc """
  Tests for the on-watchlist-add backfill worker (LON-115).

  Verifies the lookback window respects `:lookback_days`, that already-
  analyzed filings are skipped, and that the worker is unique by
  `:ticker_id` so multi-user adds collapse to a single backfill job.
  """

  use LongOrShort.DataCase, async: false
  use Oban.Testing, repo: LongOrShort.Repo

  import LongOrShort.{FilingsFixtures, TickersFixtures}

  alias LongOrShort.AI.MockProvider
  alias LongOrShort.Filings
  alias LongOrShort.Filings.Workers.FilingAnalysisBackfillWorker

  setup do
    MockProvider.reset()

    original_models = Application.fetch_env!(:long_or_short, :filing_extraction_models)

    Application.put_env(
      :long_or_short,
      :filing_extraction_models,
      Map.put(original_models, MockProvider, %{cheap: "mock-cheap", complex: "mock-complex"})
    )

    on_exit(fn ->
      Application.put_env(:long_or_short, :filing_extraction_models, original_models)
    end)

    :ok
  end

  defp tool_response do
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
       usage: %{input_tokens: 100, output_tokens: 50}
     }}
  end

  defp filing_for_ticker(ticker, filed_at, symbol_seed) do
    unique = System.unique_integer([:positive])

    filing =
      build_filing_for_ticker(ticker, %{
        filing_type: :s3,
        external_id: "back-#{symbol_seed}-#{unique}",
        filer_cik: "0000#{unique}",
        filed_at: filed_at
      })

    _ = build_filing_raw(filing)
    filing
  end

  describe "perform/1 — lookback window" do
    test "analyzes filings within the lookback window and skips older ones" do
      MockProvider.stub(fn _, _, _ -> tool_response() end)

      ticker = build_ticker(%{symbol: "BACKWND"})
      now = DateTime.utc_now()

      recent_a = filing_for_ticker(ticker, DateTime.add(now, -7 * 86_400, :second), "a")
      recent_b = filing_for_ticker(ticker, DateTime.add(now, -60 * 86_400, :second), "b")
      old = filing_for_ticker(ticker, DateTime.add(now, -120 * 86_400, :second), "c")

      assert :ok =
               perform_job(FilingAnalysisBackfillWorker, %{
                 "ticker_id" => ticker.id,
                 "lookback_days" => 90
               })

      assert {:ok, %{id: _}} =
               Filings.get_filing_analysis_by_filing(recent_a.id, authorize?: false)

      assert {:ok, %{id: _}} =
               Filings.get_filing_analysis_by_filing(recent_b.id, authorize?: false)

      assert {:ok, nil} =
               Filings.get_filing_analysis_by_filing(old.id, authorize?: false)
    end

    test "default lookback is 90 days when arg absent" do
      MockProvider.stub(fn _, _, _ -> tool_response() end)

      ticker = build_ticker(%{symbol: "BACKDEF"})
      now = DateTime.utc_now()

      within = filing_for_ticker(ticker, DateTime.add(now, -30 * 86_400, :second), "d")
      outside = filing_for_ticker(ticker, DateTime.add(now, -100 * 86_400, :second), "e")

      assert :ok = perform_job(FilingAnalysisBackfillWorker, %{"ticker_id" => ticker.id})

      assert {:ok, %{id: _}} =
               Filings.get_filing_analysis_by_filing(within.id, authorize?: false)

      assert {:ok, nil} =
               Filings.get_filing_analysis_by_filing(outside.id, authorize?: false)
    end
  end

  describe "perform/1 — already-analyzed filings" do
    test "skips filings that already have a FilingAnalysis row" do
      MockProvider.stub(fn _, _, _ -> tool_response() end)

      ticker = build_ticker(%{symbol: "BACKEXIST"})
      filing = filing_for_ticker(ticker, DateTime.utc_now(), "f")
      _ = build_filing_analysis(filing, %{summary: "pre-existing"})

      assert :ok =
               perform_job(FilingAnalysisBackfillWorker, %{
                 "ticker_id" => ticker.id,
                 "lookback_days" => 90
               })

      assert {:ok, analysis} =
               Filings.get_filing_analysis_by_filing(filing.id, authorize?: false)

      assert analysis.summary == "pre-existing"
    end
  end

  describe "perform/1 — empty backfill" do
    test "returns :ok when ticker has no filings in the window" do
      ticker = build_ticker(%{symbol: "BACKEMPTY"})

      assert :ok =
               perform_job(FilingAnalysisBackfillWorker, %{
                 "ticker_id" => ticker.id,
                 "lookback_days" => 90
               })
    end
  end

  describe "new_job/2" do
    test "builds an Oban job with ticker_id and default lookback_days" do
      ticker_id = Ash.UUID.generate()

      changeset = FilingAnalysisBackfillWorker.new_job(ticker_id)

      assert changeset.changes.args == %{"ticker_id" => ticker_id, "lookback_days" => 90}
      assert changeset.changes.worker == "LongOrShort.Filings.Workers.FilingAnalysisBackfillWorker"
    end

    test "honors :lookback_days override" do
      ticker_id = Ash.UUID.generate()

      changeset = FilingAnalysisBackfillWorker.new_job(ticker_id, lookback_days: 30)

      assert changeset.changes.args == %{"ticker_id" => ticker_id, "lookback_days" => 30}
    end
  end
end
