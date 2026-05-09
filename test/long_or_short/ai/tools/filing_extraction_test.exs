defmodule LongOrShort.AI.Tools.FilingExtractionTest do
  @moduledoc """
  Schema-shape tests for `LongOrShort.AI.Tools.FilingExtraction`.

  Pure data tests — no LLM call. Catches schema drift, missing
  fields, and required-list inversions that would let the LLM duck
  decisions it must make.
  """

  use ExUnit.Case, async: true

  doctest LongOrShort.AI.Tools.FilingExtraction

  alias LongOrShort.AI.Tools.FilingExtraction

  describe "spec/0" do
    test "matches the Provider.tool_spec shape" do
      spec = FilingExtraction.spec()

      assert is_binary(spec.name)
      assert is_binary(spec.description)
      assert is_map(spec.input_schema)
    end

    test "names the tool record_filing_extraction" do
      assert FilingExtraction.spec().name == "record_filing_extraction"
    end

    test "description forbids judgment / severity scoring" do
      desc = String.downcase(FilingExtraction.spec().description)
      assert desc =~ "extract only"
      assert desc =~ "do not score severity"
    end

    test "input_schema is an object with all 17 expected properties" do
      schema = FilingExtraction.spec().input_schema

      assert schema.type == "object"

      expected = ~w(
            dilution_type deal_size_usd share_count
            pricing_method pricing_discount_pct
            warrant_strike warrant_term_years
            atm_remaining_shares atm_total_authorized_shares
            shelf_total_authorized_usd shelf_remaining_usd
            convertible_conversion_price
            has_anti_dilution_clause has_death_spiral_convertible
            is_reverse_split_proxy reverse_split_ratio
            summary
          )a

      assert length(expected) == 17

      actual = Map.keys(schema.properties) |> MapSet.new()
      missing = MapSet.difference(MapSet.new(expected), actual)

      assert MapSet.size(missing) == 0,
             "missing properties: #{inspect(MapSet.to_list(missing))}"
    end

    test "required list contains exactly the 6 fields the LLM must always answer" do
      required = FilingExtraction.spec().input_schema.required

      expected_required = ~w(
        dilution_type
        pricing_method
        has_anti_dilution_clause
        has_death_spiral_convertible
        is_reverse_split_proxy
        summary
      )

      assert Enum.sort(required) == Enum.sort(expected_required)
    end

    test "all booleans are required (no ducking the question with null)" do
      required = MapSet.new(FilingExtraction.spec().input_schema.required)

      assert "has_anti_dilution_clause" in required
      assert "has_death_spiral_convertible" in required
      assert "is_reverse_split_proxy" in required
    end

    test "numeric fields are NOT required (nullable)" do
      required = MapSet.new(FilingExtraction.spec().input_schema.required)

      nullable_numerics = ~w(
        deal_size_usd share_count pricing_discount_pct
        warrant_strike warrant_term_years
        atm_remaining_shares atm_total_authorized_shares
        shelf_total_authorized_usd shelf_remaining_usd
        convertible_conversion_price
      )

      for field <- nullable_numerics do
        refute field in required,
               "#{field} should be nullable, but is in required: #{inspect(MapSet.to_list(required))}"
      end
    end

    test "dilution_type enum matches dilution_types/0" do
      schema_enum = FilingExtraction.spec().input_schema.properties.dilution_type.enum
      assert Enum.sort(schema_enum) == Enum.sort(FilingExtraction.dilution_types())
    end

    test "pricing_method enum matches pricing_methods/0" do
      schema_enum = FilingExtraction.spec().input_schema.properties.pricing_method.enum
      assert Enum.sort(schema_enum) == Enum.sort(FilingExtraction.pricing_methods())
    end

    test "dilution_types/0 includes :none for non-dilutive filings" do
      assert "none" in FilingExtraction.dilution_types()
    end

    test "pricing_methods/0 includes 'unknown' (LLM must not guess)" do
      assert "unknown" in FilingExtraction.pricing_methods()
    end
  end
end
