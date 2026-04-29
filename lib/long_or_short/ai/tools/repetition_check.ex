defmodule LongOrShort.AI.Tools.RepetitionCheck do
  @moduledoc """
  Tool spec for repetition analysis. Provider-agnostic.

  Implements the `t:LongOrShort.AI.Provider.tool_spec/0` contract so any
  provider (Claude, Qwen, etc.) can convert it to its own native format.

  When adding a new analysis type (e.g. `PricePatternCheck`), follow this
  same shape: a `spec/0` returning a `%{name, description, input_schema}`
  map. Provider implementations handle the per-API translation.
  """

  @doc """
  Returns the tool spec describing the repetition-analysis output schema.

  ## Examples

      iex> spec = LongOrShort.AI.Tools.RepetitionCheck.spec()
      iex> spec.name
      "report_repetition_analysis"

      iex> LongOrShort.AI.Tools.RepetitionCheck.spec().input_schema.required
      ["is_repetition", "repetition_count", "fatigue_level", "reasoning"]
  """
  @spec spec() :: LongOrShort.AI.Provider.tool_spec()
  def spec do
    %{
      name: "report_repetition_analysis",
      description: """
      Analyzes whether a new news article repeats a theme already covered \
      by previous articles for the same ticker. Reports the repetition \
      count and market fatigue level so a momentum trader can decide \
      GO / WATCH / SKIP at a glance.\
      """,
      input_schema: %{
        type: "object",
        properties: %{
          is_repetition: %{
            type: "boolean",
            description: "Whether this article repeats a theme from past articles."
          },
          theme: %{
            type: "string",
            description:
              "Short theme label (e.g. 'Aero Velocity partnership'). Null when is_repetition is false."
          },
          repetition_count: %{
            type: "integer",
            minimum: 1,
            description:
              "Number of times this theme has appeared, including this article. 1 if first."
          },
          related_article_ids: %{
            type: "array",
            items: %{type: "string"},
            description: "IDs of past articles that share the same theme."
          },
          fatigue_level: %{
            type: "string",
            enum: ["low", "medium", "high"],
            description:
              "Market fatigue level. low = fresh, medium = some repetition, high = heavily repeated."
          },
          reasoning: %{
            type: "string",
            description: "1-3 sentences explaining the analysis."
          }
        },
        required: ["is_repetition", "repetition_count", "fatigue_level", "reasoning"]
      }
    }
  end
end
