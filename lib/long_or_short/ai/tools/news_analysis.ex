defmodule LongOrShort.AI.Tools.NewsAnalysis do
  @moduledoc """
  Tool spec for momentum analysis. Provider-agnostic.

  Implements the `t:LongOrShort.AI.Provider.tool_spec/0` contract (LON-23)
  so any provider (Claude today, Qwen or others later) can convert it to
  its native tool format.

  ## What is a tool spec?

  A tool spec is a structured-output contract handed to the LLM alongside
  the messages. Instead of producing free text, the model can choose to
  invoke the named tool with typed parameters validated against
  `input_schema` (a JSON Schema fragment). The provider returns the tool
  call as a structured value our code consumes directly — no JSON
  parsing out of model prose, no hallucinated enum values.

  This is Anthropic's "Tool Use" feature; OpenAI calls the same idea
  "function calling". `LongOrShort.AI.Provider` normalizes both into the
  same `t:LongOrShort.AI.Provider.tool_spec/0` shape
  (`%{name, description, input_schema}`).

  For momentum analysis the trade-offs land on tool use: deterministic
  Card shape, enum values validated at the API boundary, and one
  round-trip per article instead of model → text → regex → struct.

  ## Phase 1 stubs

  The schema mirrors the writable columns of
  `LongOrShort.Analysis.NewsAnalysis` (LON-79) **except** the two
  fields that aren't LLM-shaped:

    * `:pump_fade_risk` — defaults to `:insufficient_data` until Phase 4
      derives it from a `price_reactions` history table.
    * `:strategy_match` — defaults to `:partial` until Phase 2 derives
      it from rule-based price/float/RVOL signals.

  Asking the LLM to guess those from a headline alone produces
  hallucination, so they are intentionally absent from the input schema.
  `LongOrShort.Analysis.MomentumAnalyzer` (LON-82) writes the stub
  defaults when persisting the row.

  ## Required vs optional

  Eleven fields are required, one is optional:

    * **Required:** `:catalyst_strength`, `:catalyst_type`, `:sentiment`,
      `:repetition_count`, `:verdict`, `:headline_takeaway`, and the
      five `:detail_*` fields.
    * **Optional:** `:repetition_summary` — only meaningful when
      `:repetition_count > 1`.

  `:repetition_count` itself is required (defaulting to `1`) so the
  model is forced to think about repetition explicitly even when no
  past articles were supplied.

  ## Adding a new tool

  Follow the shape: a `spec/0` function returning a
  `%{name, description, input_schema}` map. Provider implementations
  handle the per-API translation (Anthropic uses snake_case top-level
  fields, OpenAI uses `parameters` instead of `input_schema`, etc.).
  """
  @doc """
  Returns the tool spec describing the momentum-analysis output schema.

  Consumed by `LongOrShort.AI.Provider.call/3` — provider implementations
  translate the returned shape into their native tool request format
  (Anthropic Messages API `tools`, OpenAI `tools`, etc.).

  ## Examples

      iex> spec = LongOrShort.AI.Tools.NewsAnalysis.spec()
      iex> spec.name
      "record_news_analysis"

      iex> schema = LongOrShort.AI.Tools.NewsAnalysis.spec().input_schema
      iex> schema.type
      "object"

      iex> required = LongOrShort.AI.Tools.NewsAnalysis.spec().input_schema.required
      iex> "verdict" in required and "headline_takeaway" in required
      true

      iex> verdict = LongOrShort.AI.Tools.NewsAnalysis.spec().input_schema.properties.verdict
      iex> Enum.sort(verdict.enum)
      ["skip", "trade", "watch"]
  """
  @spec spec() :: LongOrShort.AI.Provider.tool_spec()
  def spec do
    %{
      name: "record_news_analysis",
      description: """
      Record a comprehensive momentum-trading analysis of a small-cap news \
      article. The output drives a one-glance trading card (six signals + \
      headline) plus an expandable five-section detail view.\
      """,
      input_schema: %{
        type: "object",
        properties: %{
          # ── Card-level signals ────────────────────────────────
          catalyst_strength: %{
            type: "string",
            enum: ~w(strong medium weak unknown),
            description:
              "How strong this catalyst is as a momentum trigger. Use 'unknown' only when the article gives no signal at all."
          },
          catalyst_type: %{
            type: "string",
            enum:
              ~w(partnership ma fda earnings offering rfp contract_win guidance clinical regulatory other),
            description:
              "Kind of news event. Use 'other' only when nothing fits — prefer the closest match."
          },
          sentiment: %{
            type: "string",
            enum: ~w(positive neutral negative),
            description: "Directional bias of the news content itself."
          },
          repetition_count: %{
            type: "integer",
            minimum: 1,
            description:
              "Nth occurrence of this theme for this ticker, including this article. 1 = first, 4 = the 4th similar article."
          },
          repetition_summary: %{
            type: "string",
            description:
              "Short label for the repetition cluster when count > 1, e.g. \"Aero Velocity 파트너십 4번째\". Omit when count == 1."
          },
          verdict: %{
            type: "string",
            enum: ~w(trade watch skip),
            description:
              "Trader-facing call: 'trade' = take it, 'watch' = monitor for a better entry, 'skip' = pass entirely."
          },

          # ── Card summary ─────────────────────────────────────
          headline_takeaway: %{
            type: "string",
            description:
              "One trader-voice sentence summarising the verdict. Korean is fine — write in the trader's natural language."
          },

          # ── Detail view (Markdown) ───────────────────────────
          detail_summary: %{
            type: "string",
            description: "What the news actually says, in plain language. 2–4 sentences."
          },
          detail_positives: %{
            type: "string",
            description: "Bullish reading and momentum factors. Markdown bullet list."
          },
          detail_concerns: %{
            type: "string",
            description:
              "Bearish reading, fade risks, things to be cautious of. Markdown bullet list."
          },
          detail_checklist: %{
            type: "string",
            description:
              "Pre-entry checks (price band, float, RVOL, EMA alignment). Markdown bullet list."
          },
          detail_recommendation: %{
            type: "string",
            description: "Concrete suggested action with reasoning. 2–3 sentences."
          }
        },
        required: ~w(
               catalyst_strength catalyst_type sentiment repetition_count verdict
               headline_takeaway detail_summary detail_positives detail_concerns
               detail_checklist detail_recommendation
             )
      }
    }
  end
end
