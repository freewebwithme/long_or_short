defmodule LongOrShort.AI.Tools.RepetitionCheckTest do
  use ExUnit.Case, async: true

  doctest LongOrShort.AI.Tools.RepetitionCheck

  alias LongOrShort.AI.Tools.RepetitionCheck

  describe "spec/0" do
    test "matches the Provider.tool_spec shape" do
      spec = RepetitionCheck.spec()

      assert is_binary(spec.name)
      assert is_binary(spec.description)
      assert is_map(spec.input_schema)
    end

    test "names the tool report_repetition_analysis" do
      assert RepetitionCheck.spec().name == "report_repetition_analysis"
    end

    test "input_schema is an object with the expected properties" do
      schema = RepetitionCheck.spec().input_schema

      assert schema.type == "object"

      expected = ~w(
          is_repetition theme repetition_count related_article_ids
          fatigue_level reasoning
        )a

      for key <- expected do
        assert Map.has_key?(schema.properties, key),
               "expected property #{inspect(key)} in input_schema"
      end
    end

    test "marks core fields as required (theme + related_article_ids optional)" do
      required = RepetitionCheck.spec().input_schema.required

      assert "is_repetition" in required
      assert "repetition_count" in required
      assert "fatigue_level" in required
      assert "reasoning" in required

      refute "theme" in required
      refute "related_article_ids" in required
    end

    test "fatigue_level enum is exactly low/medium/high" do
      enum = RepetitionCheck.spec().input_schema.properties.fatigue_level.enum
      assert Enum.sort(enum) == ~w(high low medium)
    end

    test "repetition_count must be at least 1" do
      assert RepetitionCheck.spec().input_schema.properties.repetition_count.minimum == 1
    end
  end
end
