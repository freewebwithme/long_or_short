defmodule LongOrShort.Filings.Workers.FilingAnalysisWorkerTest do
  @moduledoc """
  Tests for the watchlist-scoped cron worker (LON-115).

  Verifies the core acceptance criterion: only filings whose ticker is
  on at least one trader's watchlist get analyzed; non-watchlist
  filings stay untouched even if they have a body persisted.
  """

  use LongOrShort.DataCase, async: false
  use Oban.Testing, repo: LongOrShort.Repo

  import LongOrShort.{FilingsFixtures, TickersFixtures}

  alias LongOrShort.AI.MockProvider
  alias LongOrShort.Filings
  alias LongOrShort.Filings.Workers.FilingAnalysisWorker

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

  defp setup_filing_with_raw(symbol, filing_type \\ :s3) do
    filing = build_filing(%{filing_type: filing_type, symbol: symbol})
    _raw = build_filing_raw(filing)
    filing
  end

  # ── Watchlist scoping ──────────────────────────────────────────

  describe "perform/1 — watchlist scoping" do
    test "analyzes only filings whose ticker is on a watchlist" do
      MockProvider.stub(fn _, _, _ -> tool_response() end)

      watched = setup_filing_with_raw("WATCHED")
      unwatched = setup_filing_with_raw("UNWATCHED")

      _ = build_watchlist_item(%{ticker_id: watched.ticker_id})

      assert :ok = perform_job(FilingAnalysisWorker, %{})

      assert {:ok, %{id: _}} =
               Filings.get_filing_analysis_by_filing(watched.id, authorize?: false)

      assert {:ok, nil} =
               Filings.get_filing_analysis_by_filing(unwatched.id, authorize?: false)
    end

    test "returns :ok with no work when no tickers are on any watchlist" do
      _filing = setup_filing_with_raw("LONELY")

      assert :ok = perform_job(FilingAnalysisWorker, %{})

      assert :ok
    end

    test "skips filings that already have an analysis" do
      MockProvider.stub(fn _, _, _ -> tool_response() end)

      filing = setup_filing_with_raw("ALREADY")
      _ = build_watchlist_item(%{ticker_id: filing.ticker_id})
      _ = build_filing_analysis(filing, %{summary: "pre-existing analysis"})

      # No MockProvider call should happen — the row is already there.
      assert :ok = perform_job(FilingAnalysisWorker, %{})

      assert {:ok, analysis} =
               Filings.get_filing_analysis_by_filing(filing.id, authorize?: false)

      assert analysis.summary == "pre-existing analysis"
    end

    test "skips filings that have no FilingRaw body yet" do
      MockProvider.stub(fn _, _, _ -> tool_response() end)

      filing = build_filing(%{filing_type: :s3, symbol: "NOBODY"})
      _ = build_watchlist_item(%{ticker_id: filing.ticker_id})

      assert :ok = perform_job(FilingAnalysisWorker, %{})

      assert {:ok, nil} =
               Filings.get_filing_analysis_by_filing(filing.id, authorize?: false)
    end
  end

  # ── Multiple watchlist tickers ─────────────────────────────────

  describe "perform/1 — multiple watchlist tickers" do
    test "analyzes filings for every watchlist ticker" do
      MockProvider.stub(fn _, _, _ -> tool_response() end)

      filing_a = setup_filing_with_raw("MULTIA")
      filing_b = setup_filing_with_raw("MULTIB")

      _ = build_watchlist_item(%{ticker_id: filing_a.ticker_id})
      _ = build_watchlist_item(%{ticker_id: filing_b.ticker_id})

      assert :ok = perform_job(FilingAnalysisWorker, %{})

      assert {:ok, %{id: _}} =
               Filings.get_filing_analysis_by_filing(filing_a.id, authorize?: false)

      assert {:ok, %{id: _}} =
               Filings.get_filing_analysis_by_filing(filing_b.id, authorize?: false)
    end
  end
end
