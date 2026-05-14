defmodule LongOrShort.Filings.AnalyzerTest do
  @moduledoc """
  Integration tests for `LongOrShort.Filings.Analyzer` (LON-115, Stage 3c;
  two-tier split in LON-134).

  Covers:

    * `analyze_filing/1` (orchestrator) — three quality outcomes
      (`:high`, `:rejected`-via-validation, `:rejected`-via-LLM),
      PubSub broadcast, skip-without-persist, idempotent re-runs.
    * `extract_keywords/1` (Tier 1 only) — persists with
      `dilution_severity = nil`, both success and LLM-failure paths.
    * `score_severity/1` (Tier 2 only) — fills the verdict on a Tier 1
      row, short-circuits on rejected, downgrades quality via Scoring
      validation.
  """

  use LongOrShort.DataCase, async: false

  import LongOrShort.FilingsFixtures

  alias LongOrShort.AI.MockProvider
  alias LongOrShort.Filings
  alias LongOrShort.Filings.{Events, FilingAnalysis}

  setup do
    MockProvider.reset()

    # Register MockProvider in the model map so Router.model_for_tier
    # resolves successfully during extraction.
    original_models = Application.fetch_env!(:long_or_short, :filing_extraction_models)

    Application.put_env(
      :long_or_short,
      :filing_extraction_models,
      Map.put(original_models, MockProvider, %{cheap: "mock-cheap", complex: "mock-complex"})
    )

    on_exit(fn ->
      Application.put_env(:long_or_short, :filing_extraction_models, original_models)
    end)

    :ok = Events.subscribe()
    :ok
  end

  # ── Helpers ──────────────────────────────────────────────────────

  defp valid_extracted_input(overrides \\ %{}) do
    Map.merge(
      %{
        "dilution_type" => "atm",
        "pricing_method" => "vwap_based",
        "deal_size_usd" => 50_000_000,
        "share_count" => 1_000_000,
        "atm_remaining_shares" => nil,
        "atm_total_authorized_shares" => nil,
        "has_anti_dilution_clause" => false,
        "has_death_spiral_convertible" => false,
        "is_reverse_split_proxy" => false,
        "summary" => "ATM facility — sample"
      },
      overrides
    )
  end

  defp tool_response(input \\ valid_extracted_input()) do
    {:ok,
     %{
       tool_calls: [%{name: "record_filing_extraction", input: input}],
       text: nil,
       usage: %{input_tokens: 1500, output_tokens: 100}
     }}
  end

  defp build_setup(filing_overrides, raw_overrides \\ %{}) do
    filing = build_filing(filing_overrides)
    _raw = build_filing_raw(filing, raw_overrides)
    filing
  end

  # ── Happy path — :high quality ─────────────────────────────────

  describe "analyze_filing/1 — :high quality outcomes" do
    test "default_low rule produces :high quality + :low severity" do
      filing = build_setup(%{filing_type: :s3, symbol: "ATMLOW"})

      MockProvider.stub(fn _, _, _ -> tool_response() end)

      assert {:ok, %FilingAnalysis{} = analysis} = Filings.analyze_filing(filing.id)

      assert analysis.filing_id == filing.id
      assert analysis.ticker_id == filing.ticker_id
      assert analysis.extraction_quality == :high
      assert analysis.dilution_severity == :low
      assert analysis.matched_rules == [:rule_default_low]
      assert analysis.dilution_type == :atm
      assert analysis.pricing_method == :vwap_based
      assert analysis.summary =~ "ATM"
      assert analysis.rejected_reason == nil
    end

    test "extraction fields are persisted verbatim" do
      filing = build_setup(%{filing_type: :s3, symbol: "ATMFIELDS"})

      MockProvider.stub(fn _, _, _ ->
        tool_response(
          valid_extracted_input(%{
            "deal_size_usd" => 25_000_000,
            "share_count" => 5_000_000,
            "summary" => "Custom summary text"
          })
        )
      end)

      assert {:ok, analysis} = Filings.analyze_filing(filing.id)

      assert Decimal.equal?(analysis.deal_size_usd, Decimal.new("25000000"))
      assert analysis.share_count == 5_000_000
      assert analysis.summary == "Custom summary text"
    end
  end

  # ── :rejected via Validation ───────────────────────────────────

  describe "analyze_filing/1 — :rejected via validation" do
    test "negative share_count triggers Validation rejection and persists :rejected" do
      filing = build_setup(%{filing_type: :s3, symbol: "REJVAL"})

      MockProvider.stub(fn _, _, _ ->
        tool_response(valid_extracted_input(%{"share_count" => -100}))
      end)

      assert {:ok, %FilingAnalysis{} = analysis} = Filings.analyze_filing(filing.id)

      assert analysis.extraction_quality == :rejected
      assert analysis.dilution_severity == :none
      assert analysis.matched_rules == []
      assert analysis.rejected_reason =~ "validation:"
      assert analysis.rejected_reason =~ "share_count"
    end

    test "extraction fields are still recorded on rejected rows" do
      filing = build_setup(%{filing_type: :s3, symbol: "REJEXTRA"})

      MockProvider.stub(fn _, _, _ ->
        tool_response(valid_extracted_input(%{"share_count" => -1}))
      end)

      assert {:ok, analysis} = Filings.analyze_filing(filing.id)

      assert analysis.dilution_type == :atm
      assert analysis.pricing_method == :vwap_based
      assert analysis.summary =~ "ATM"
    end
  end

  # ── :rejected via LLM error ────────────────────────────────────

  describe "analyze_filing/1 — :rejected via LLM error" do
    test ":no_tool_call persists a :rejected row with error provenance" do
      filing = build_setup(%{filing_type: :s3, symbol: "LLMNOTOOL"})

      MockProvider.stub(fn _, _, _ ->
        {:ok, %{tool_calls: [], text: "I cannot do that.", usage: %{}}}
      end)

      assert {:ok, %FilingAnalysis{} = analysis} = Filings.analyze_filing(filing.id)

      assert analysis.extraction_quality == :rejected
      assert analysis.dilution_severity == :none
      assert analysis.dilution_type == :none
      assert analysis.pricing_method == :unknown
      assert analysis.rejected_reason == "extractor:no_tool_call"
      assert analysis.raw_response["error"] != nil
      assert analysis.model == "unknown"
    end

    test ":invalid_enum persists a :rejected row" do
      filing = build_setup(%{filing_type: :s3, symbol: "LLMENUM"})

      MockProvider.stub(fn _, _, _ ->
        tool_response(valid_extracted_input(%{"dilution_type" => "atm_disco"}))
      end)

      assert {:ok, analysis} = Filings.analyze_filing(filing.id)

      assert analysis.extraction_quality == :rejected
      assert analysis.rejected_reason =~ "invalid_enum"
      assert analysis.rejected_reason =~ "dilution_type"
    end
  end

  # ── Skip cases — no persistence ────────────────────────────────

  describe "analyze_filing/1 — skip-without-persist" do
    test ":filing_raw_missing returns error and does not persist" do
      filing = build_filing(%{filing_type: :s3, symbol: "NORAW"})

      assert {:error, :filing_raw_missing} = Filings.analyze_filing(filing.id)
      assert {:ok, nil} = Filings.get_filing_analysis_by_filing(filing.id, authorize?: false)
    end

    test ":not_supported returns error and does not persist" do
      filing = build_setup(%{filing_type: :form4, symbol: "FORM4"})

      assert {:error, :not_supported} = Filings.analyze_filing(filing.id)
      assert {:ok, nil} = Filings.get_filing_analysis_by_filing(filing.id, authorize?: false)
    end

    test ":no_relevant_content returns error and does not persist" do
      filing =
        build_setup(%{filing_type: :def14a, symbol: "DEFNORE"}, %{
          raw_text: "Routine annual meeting. Election of directors. Ratification of auditors."
        })

      assert {:error, :no_relevant_content} = Filings.analyze_filing(filing.id)
      assert {:ok, nil} = Filings.get_filing_analysis_by_filing(filing.id, authorize?: false)
    end
  end

  # ── PubSub broadcast ───────────────────────────────────────────

  describe "analyze_filing/1 — PubSub broadcast" do
    test "broadcasts :new_filing_analysis on the global topic for :high outcome" do
      filing = build_setup(%{filing_type: :s3, symbol: "PUBHIGH"})
      MockProvider.stub(fn _, _, _ -> tool_response() end)

      assert {:ok, analysis} = Filings.analyze_filing(filing.id)

      assert_receive {:new_filing_analysis, %FilingAnalysis{} = received}, 500
      assert received.id == analysis.id
      assert received.dilution_severity == :low
    end

    test "broadcasts on :rejected outcomes too (Stage 7 alerts filter quality)" do
      filing = build_setup(%{filing_type: :s3, symbol: "PUBREJ"})

      MockProvider.stub(fn _, _, _ ->
        tool_response(valid_extracted_input(%{"share_count" => -10}))
      end)

      assert {:ok, _analysis} = Filings.analyze_filing(filing.id)

      assert_receive {:new_filing_analysis, %FilingAnalysis{extraction_quality: :rejected}}, 500
    end

    test "no broadcast for skip cases" do
      filing = build_setup(%{filing_type: :form4, symbol: "PUBSKIP"})

      assert {:error, :not_supported} = Filings.analyze_filing(filing.id)
      refute_receive {:new_filing_analysis, _}, 100
    end
  end

  # ── Provenance ─────────────────────────────────────────────────

  describe "analyze_filing/1 — provenance" do
    test "raw_response includes usage for successful runs" do
      filing = build_setup(%{filing_type: :s3, symbol: "PROV"})
      MockProvider.stub(fn _, _, _ -> tool_response() end)

      assert {:ok, analysis} = Filings.analyze_filing(filing.id)

      assert analysis.provider =~ "MockProvider"
      assert analysis.model == "mock-complex"
      assert analysis.raw_response["usage"]["input_tokens"] == 1500
    end
  end

  # ── Idempotency ────────────────────────────────────────────────

  describe "analyze_filing/1 — idempotency" do
    test "re-running on the same filing updates the existing row via upsert" do
      filing = build_setup(%{filing_type: :s3, symbol: "IDEMPOT"})

      MockProvider.stub(fn _, _, _ ->
        tool_response(valid_extracted_input(%{"summary" => "First run"}))
      end)

      assert {:ok, first} = Filings.analyze_filing(filing.id)

      MockProvider.stub(fn _, _, _ ->
        tool_response(valid_extracted_input(%{"summary" => "Second run"}))
      end)

      assert {:ok, second} = Filings.analyze_filing(filing.id)

      assert first.id == second.id
      assert second.summary == "Second run"
    end
  end

  # ── Tier 1: extract_keywords ────────────────────────────────────

  describe "extract_keywords/1 — Tier 1 only" do
    test "persists FilingAnalysis with severity nil on :high outcome" do
      filing = build_setup(%{filing_type: :s3, symbol: "TIER1OK"})
      MockProvider.stub(fn _, _, _ -> tool_response() end)

      assert {:ok, %FilingAnalysis{} = analysis} = Filings.extract_keywords(filing.id)

      assert analysis.extraction_quality == :high
      assert analysis.dilution_severity == nil
      assert analysis.matched_rules == []
      assert analysis.severity_reason == nil

      # Tier 1 jsonb + projected columns both populated.
      assert is_map(analysis.extracted_keywords)
      assert analysis.dilution_type == :atm
      assert analysis.pricing_method == :vwap_based
      assert analysis.summary =~ "ATM"
    end

    test "persists :rejected Tier 1 row with severity nil on LLM failure" do
      filing = build_setup(%{filing_type: :s3, symbol: "TIER1FAIL"})

      MockProvider.stub(fn _, _, _ ->
        {:ok, %{tool_calls: [], text: "no", usage: %{}}}
      end)

      assert {:ok, %FilingAnalysis{} = analysis} = Filings.extract_keywords(filing.id)

      assert analysis.extraction_quality == :rejected
      assert analysis.dilution_severity == nil
      assert analysis.extracted_keywords == nil
      assert analysis.rejected_reason == "extractor:no_tool_call"
    end

    test "returns :filing_raw_missing without persisting" do
      filing = build_filing(%{filing_type: :s3, symbol: "TIER1NORAW"})

      assert {:error, :filing_raw_missing} = Filings.extract_keywords(filing.id)
      assert {:ok, nil} = Filings.get_filing_analysis_by_filing(filing.id, authorize?: false)
    end

    test "broadcasts :new_filing_analysis after Tier 1 write" do
      filing = build_setup(%{filing_type: :s3, symbol: "TIER1PUB"})
      MockProvider.stub(fn _, _, _ -> tool_response() end)

      assert {:ok, analysis} = Filings.extract_keywords(filing.id)

      assert_receive {:new_filing_analysis, %FilingAnalysis{} = received}, 500
      assert received.id == analysis.id
      assert received.dilution_severity == nil
    end
  end

  # ── Tier 2: score_severity ──────────────────────────────────────

  describe "score_severity/1 — Tier 2 only" do
    test "fills the severity verdict on an existing :high Tier 1 row" do
      filing = build_setup(%{filing_type: :s3, symbol: "TIER2OK"})
      MockProvider.stub(fn _, _, _ -> tool_response() end)
      {:ok, tier_1} = Filings.extract_keywords(filing.id)
      assert tier_1.dilution_severity == nil

      assert {:ok, %FilingAnalysis{} = tier_2} = Filings.score_severity(tier_1.id)
      assert tier_2.id == tier_1.id
      assert tier_2.dilution_severity == :low
      assert tier_2.matched_rules == [:rule_default_low]
      assert tier_2.extraction_quality == :high
    end

    test "short-circuits to severity = :none on a :rejected Tier 1 row" do
      filing = build_setup(%{filing_type: :s3, symbol: "TIER2REJ"})

      MockProvider.stub(fn _, _, _ ->
        {:ok, %{tool_calls: [], text: nil, usage: %{}}}
      end)

      {:ok, tier_1} = Filings.extract_keywords(filing.id)
      assert tier_1.extraction_quality == :rejected

      assert {:ok, tier_2} = Filings.score_severity(tier_1.id)
      assert tier_2.dilution_severity == :none
      assert tier_2.matched_rules == []
      assert tier_2.severity_reason == nil
      # Quality stays :rejected (Tier 1 already set it; the short-circuit
      # doesn't touch quality or rejected_reason).
      assert tier_2.extraction_quality == :rejected
      assert tier_2.rejected_reason == "extractor:no_tool_call"
    end

    test "downgrades quality to :rejected when Scoring validation rejects" do
      filing = build_setup(%{filing_type: :s3, symbol: "TIER2DOWN"})

      MockProvider.stub(fn _, _, _ ->
        tool_response(valid_extracted_input(%{"share_count" => -1}))
      end)

      {:ok, tier_1} = Filings.extract_keywords(filing.id)
      # Extractor accepts negative share_count; Scoring's Validation
      # rejects it on the Tier 2 pass.
      assert tier_1.extraction_quality == :high
      assert tier_1.dilution_severity == nil

      assert {:ok, tier_2} = Filings.score_severity(tier_1.id)
      assert tier_2.extraction_quality == :rejected
      assert tier_2.dilution_severity == :none
      assert tier_2.rejected_reason =~ "validation:"
    end

    test "accepts a FilingAnalysis struct directly (skips the DB lookup)" do
      filing = build_setup(%{filing_type: :s3, symbol: "TIER2STRUCT"})
      MockProvider.stub(fn _, _, _ -> tool_response() end)
      {:ok, tier_1} = Filings.extract_keywords(filing.id)

      assert {:ok, tier_2} = Filings.score_severity(tier_1)
      assert tier_2.dilution_severity == :low
    end

    test "broadcasts :new_filing_analysis after Tier 2 write" do
      filing = build_setup(%{filing_type: :s3, symbol: "TIER2PUB"})
      MockProvider.stub(fn _, _, _ -> tool_response() end)
      {:ok, tier_1} = Filings.extract_keywords(filing.id)

      # Drain the Tier 1 broadcast first.
      assert_receive {:new_filing_analysis, _}, 500

      {:ok, _tier_2} = Filings.score_severity(tier_1.id)

      assert_receive {:new_filing_analysis, %FilingAnalysis{dilution_severity: :low}}, 500
    end

    test "returns :filing_analysis_not_found for an unknown id" do
      assert {:error, {:filing_analysis_not_found, _}} =
               Filings.score_severity(Ash.UUIDv7.generate())
    end
  end
end
