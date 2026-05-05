defmodule LongOrShort.AI.Tools.NewsAnalysisTest do
  use ExUnit.Case, async: true

  doctest LongOrShort.AI.Tools.NewsAnalysis

  alias LongOrShort.AI.Tools.NewsAnalysis

  describe "spec/0" do
    test "matches the Provider.tool_spec shape" do
      spec = NewsAnalysis.spec()

      assert is_binary(spec.name)
      assert is_binary(spec.description)
      assert is_map(spec.input_schema)
    end

    test "names the tool record_news_analysis" do
      assert NewsAnalysis.spec().name == "record_news_analysis"
    end

    test "input_schema is an object with all expected properties" do
      schema = NewsAnalysis.spec().input_schema

      assert schema.type == "object"

      expected = ~w(
            catalyst_strength catalyst_type sentiment
            repetition_count repetition_summary
            verdict headline_takeaway
            detail_summary detail_positives detail_concerns
            detail_checklist detail_recommendation
          )a

      for key <- expected do
        assert Map.has_key?(schema.properties, key),
               "expected property #{inspect(key)} in input_schema"
      end
    end

    test "does NOT include pump_fade_risk or strategy_match (Phase 1 stubs)" do
      props = NewsAnalysis.spec().input_schema.properties

      refute Map.has_key?(props, :pump_fade_risk)
      refute Map.has_key?(props, :strategy_match)
      refute Map.has_key?(props, :strategy_match_reasons)
    end

    test "marks core fields required, repetition_summary optional" do
      required = NewsAnalysis.spec().input_schema.required

      for field <-
            ~w(catalyst_strength catalyst_type sentiment repetition_count verdict
                 headline_takeaway detail_summary detail_positives detail_concerns
                 detail_checklist detail_recommendation) do
        assert field in required, "expected #{field} to be required"
      end

      refute "repetition_summary" in required
    end

    test "catalyst_strength enum matches resource constraint" do
      enum = NewsAnalysis.spec().input_schema.properties.catalyst_strength.enum
      assert Enum.sort(enum) == ~w(medium strong unknown weak)
    end

    test "catalyst_type enum matches resource constraint" do
      enum = NewsAnalysis.spec().input_schema.properties.catalyst_type.enum

      assert Enum.sort(enum) ==
               Enum.sort(~w(partnership ma fda earnings offering rfp contract_win
                      guidance clinical regulatory other))
    end

    test "sentiment enum matches resource constraint" do
      enum = NewsAnalysis.spec().input_schema.properties.sentiment.enum
      assert Enum.sort(enum) == ~w(negative neutral positive)
    end

    test "verdict enum matches resource constraint" do
      enum = NewsAnalysis.spec().input_schema.properties.verdict.enum
      assert Enum.sort(enum) == ~w(skip trade watch)
    end

    test "repetition_count requires minimum 1" do
      assert NewsAnalysis.spec().input_schema.properties.repetition_count.minimum == 1
    end
  end
end
