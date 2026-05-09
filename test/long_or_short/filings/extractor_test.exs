defmodule LongOrShort.Filings.ExtractorTest do
  @moduledoc """
  Integration tests for `LongOrShort.Filings.Extractor`.

  Uses `MockProvider` to stub the LLM response — no real API call.
  Setup adds a MockProvider entry to `:filing_extraction_models` so
  `Router.model_for_tier/2` can resolve a model when the configured
  provider is the test mock.
  """

  use LongOrShort.DataCase, async: false

  import LongOrShort.{FilingsFixtures, TickersFixtures}

  alias LongOrShort.AI.MockProvider
  alias LongOrShort.Filings.Extractor

  setup do
    MockProvider.reset()

    # Extend the model map so Router.model_for_tier can resolve when
    # the active provider is the test MockProvider.
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

  # ── Helpers ────────────────────────────────────────────────────

  defp valid_extracted_input do
    %{
      "dilution_type" => "atm",
      "pricing_method" => "vwap_based",
      "deal_size_usd" => 50_000_000,
      "share_count" => 10_000_000,
      "has_anti_dilution_clause" => false,
      "has_death_spiral_convertible" => false,
      "is_reverse_split_proxy" => false,
      "summary" => "ATM program with $50M remaining capacity at 95% of VWAP."
    }
  end

  defp tool_response(input \\ valid_extracted_input(), usage_overrides \\ %{}) do
    usage =
      Map.merge(
        %{
          input_tokens: 1500,
          output_tokens: 100,
          cache_creation_input_tokens: 0,
          cache_read_input_tokens: 1200
        },
        usage_overrides
      )

    {:ok,
     %{
       tool_calls: [%{name: "record_filing_extraction", input: input}],
       text: nil,
       usage: usage
     }}
  end

  defp build_filing_with_raw(filing_overrides \\ %{}, raw_overrides \\ %{}) do
    filing = build_filing(filing_overrides)
    _raw = build_filing_raw(filing, raw_overrides)
    filing
  end

  # ── Happy path ─────────────────────────────────────────────────

  describe "extract/2 — happy path" do
    test "returns extraction map and provenance" do
      filing = build_filing_with_raw(%{filing_type: :s3, symbol: "ATMCO"})

      MockProvider.stub(fn _, _, _ -> tool_response() end)

      assert {:ok, result} = Extractor.extract(filing)

      assert result.filing_id == filing.id
      assert result.extraction.dilution_type == :atm
      assert result.extraction.pricing_method == :vwap_based
      assert result.extraction.deal_size_usd == 50_000_000
      assert result.extraction.summary =~ "ATM program"
    end

    test "provenance includes model, tier, provider, and usage" do
      filing = build_filing_with_raw(%{filing_type: :s1, symbol: "S1CO"})

      MockProvider.stub(fn _, _, _ -> tool_response() end)

      assert {:ok, result} = Extractor.extract(filing)

      assert result.provenance.tier == :complex
      assert result.provenance.model == "mock-complex"
      assert result.provenance.provider == MockProvider
      assert result.provenance.usage.input_tokens == 1500
      assert result.provenance.usage.cache_read_input_tokens == 1200
    end
  end

  describe "extract/2 — Router integration" do
    test "S-1 filings request the :complex model from the provider" do
      filing = build_filing_with_raw(%{filing_type: :s1, symbol: "S1ROUT"})
      MockProvider.stub(fn _, _, _ -> tool_response() end)

      assert {:ok, _} = Extractor.extract(filing)

      [{_messages, _tools, opts}] = MockProvider.calls()
      assert Keyword.get(opts, :model) == "mock-complex"
    end

    test "DEF 14A filings request the :cheap model from the provider" do
      filing =
        build_filing_with_raw(%{filing_type: :def14a, symbol: "PROXY1"}, %{
          raw_text: "The Board recommends a vote FOR a reverse stock split proposal."
        })

      MockProvider.stub(fn _, _, _ -> tool_response() end)

      assert {:ok, _} = Extractor.extract(filing)

      [{_messages, _tools, opts}] = MockProvider.calls()
      assert Keyword.get(opts, :model) == "mock-cheap"
    end
  end

  describe "extract/2 — message + tool plumbing" do
    test "passes the FilingExtraction tool spec to the provider" do
      filing = build_filing_with_raw()
      MockProvider.stub(fn _, _, _ -> tool_response() end)

      assert {:ok, _} = Extractor.extract(filing)

      [{_messages, [tool], _opts}] = MockProvider.calls()
      assert tool.name == "record_filing_extraction"
    end

    test "user message includes filing metadata and ticker symbol" do
      ticker = build_ticker(%{symbol: "USERMSG"})

      filing =
        build_filing_with_raw(%{
          symbol: "USERMSG",
          filing_type: :_8k,
          filing_subtype: "8-K Item 3.02"
        })

      _ = ticker

      MockProvider.stub(fn _, _, _ -> tool_response() end)
      assert {:ok, _} = Extractor.extract(filing)

      [{[_system, %{role: "user", content: user_msg}], _tools, _opts}] = MockProvider.calls()

      assert user_msg =~ "USERMSG"
      assert user_msg =~ "_8k"
      assert user_msg =~ "Item 3.02"
    end
  end

  # ── Early exits — no LLM call ──────────────────────────────────

  describe "extract/2 — early exit conditions" do
    test "Form 4 returns :not_supported and never calls the LLM" do
      filing = build_filing_with_raw(%{filing_type: :form4})

      assert {:error, :not_supported} = Extractor.extract(filing)
      assert MockProvider.calls() == []
    end

    test "DEF 14A with no dilution keywords returns :no_relevant_content" do
      filing =
        build_filing_with_raw(%{filing_type: :def14a}, %{
          raw_text: "Routine annual meeting. Election of directors. Ratification of auditors."
        })

      assert {:error, :no_relevant_content} = Extractor.extract(filing)
      assert MockProvider.calls() == []
    end

    test "Filing without an associated FilingRaw returns :filing_raw_missing" do
      filing = build_filing()

      assert {:error, {:filing_raw_missing, id}} = Extractor.extract(filing)
      assert id == filing.id
      assert MockProvider.calls() == []
    end
  end

  # ── LLM-side error handling ────────────────────────────────────

  describe "extract/2 — LLM error handling" do
    test "missing tool call returns :no_tool_call" do
      filing = build_filing_with_raw()

      MockProvider.stub(fn _, _, _ ->
        {:ok, %{tool_calls: [], text: "I cannot do that.", usage: %{}}}
      end)

      assert {:error, :no_tool_call} = Extractor.extract(filing)
    end

    test "invalid dilution_type returns {:invalid_enum, :dilution_type, value}" do
      filing = build_filing_with_raw()

      bad_input = Map.put(valid_extracted_input(), "dilution_type", "atm_disco")

      MockProvider.stub(fn _, _, _ -> tool_response(bad_input) end)

      assert {:error, {:invalid_enum, :dilution_type, "atm_disco"}} =
               Extractor.extract(filing)
    end

    test "invalid pricing_method returns {:invalid_enum, :pricing_method, value}" do
      filing = build_filing_with_raw()

      bad_input = Map.put(valid_extracted_input(), "pricing_method", "horoscope")

      MockProvider.stub(fn _, _, _ -> tool_response(bad_input) end)

      assert {:error, {:invalid_enum, :pricing_method, "horoscope"}} =
               Extractor.extract(filing)
    end

    test "missing required enum field returns {:missing_required, field}" do
      filing = build_filing_with_raw()

      bad_input = Map.delete(valid_extracted_input(), "dilution_type")

      MockProvider.stub(fn _, _, _ -> tool_response(bad_input) end)

      assert {:error, {:missing_required, :dilution_type}} =
               Extractor.extract(filing)
    end
  end

  # ── Result shape: known atom keys ──────────────────────────────

  describe "extract/2 — result shape" do
    test "extraction map uses atom keys for all known fields" do
      filing = build_filing_with_raw()
      MockProvider.stub(fn _, _, _ -> tool_response() end)

      assert {:ok, %{extraction: extraction}} = Extractor.extract(filing)

      # Required fields always present
      assert is_atom(extraction.dilution_type)
      assert is_atom(extraction.pricing_method)
      assert is_boolean(extraction.has_anti_dilution_clause)
      assert is_boolean(extraction.has_death_spiral_convertible)
      assert is_boolean(extraction.is_reverse_split_proxy)
      assert is_binary(extraction.summary)

      # Optional fields preserved with atom keys when present
      assert Map.has_key?(extraction, :deal_size_usd)
      assert Map.has_key?(extraction, :share_count)
    end
  end
end
