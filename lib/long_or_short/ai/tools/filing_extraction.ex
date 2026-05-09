defmodule LongOrShort.AI.Tools.FilingExtraction do
  @moduledoc """
  Tool spec for SEC filing dilution-fact extraction (LON-113).

  Implements `t:LongOrShort.AI.Provider.tool_spec/0` (LON-23) so any
  provider (Claude today, Qwen or others later) can convert it to its
  native tool format.

  ## Strict scope: extraction only

  This schema deliberately does **not** include severity scores,
  recommendations, or any qualitative judgment. The LLM's job here
  is to read a filing and report verbatim facts. Severity scoring
  (Stage 3b, LON-114) is a separate, deterministic pass over these
  facts driven by hand-written rules — not by a second LLM call.

  Keeping extraction free of judgment makes the output cacheable and
  auditable, and lets us iterate on severity rules without re-running
  any LLM.

  ## Null semantics

  Most numeric fields are intentionally nullable: a 13-G filing
  doesn't have a `deal_size_usd`; a PIPE without warrants has no
  `warrant_strike`. The five **required** fields are the ones that
  every filing type can answer:

    * `dilution_type` — primary categorization (use `:none` if
      nothing dilutive is happening)
    * `pricing_method` — use `:unknown` rather than guessing
    * `has_anti_dilution_clause`, `has_death_spiral_convertible`,
      `is_reverse_split_proxy` — booleans must be explicit `true` or
      `false`; omitting them would let the LLM duck the question
    * `summary` — one-line plain-English UI string

  When a non-required field cannot be determined from the filing
  text, the LLM **omits it** (or returns `null`) rather than
  guessing. The description on each field reinforces this.

  ## Field reference

  See `LongOrShort.Filings.SectionFilter`'s glossary for filing-type
  context and what each form discloses. Per-field semantics are in
  the `description:` strings below.
  """

  # Primary categorization of the dilution event. `:none` covers
  # filings that turned out to be non-dilutive after parsing
  # (e.g. routine 13-G beneficial-ownership reports).
  @dilution_types ~w(atm s1_offering s3_shelf pipe warrant_exercise convertible_conversion reverse_split none)

  # How the offering price is determined. `:unknown` is used when
  # the filing doesn't disclose the pricing mechanism (small-cap
  # offerings sometimes leave this vague pre-pricing).
  @pricing_methods ~w(fixed market_minus_pct vwap_based unknown)

  @doc """
  Returns the tool spec describing the filing-extraction output schema.

  Consumed by `LongOrShort.AI.Provider.call/3` — provider implementations
  translate the returned shape into their native tool request format.

  ## Examples

      iex> spec = LongOrShort.AI.Tools.FilingExtraction.spec()
      iex> spec.name
      "record_filing_extraction"

      iex> schema = LongOrShort.AI.Tools.FilingExtraction.spec().input_schema
      iex> schema.type
      "object"

      iex> required = LongOrShort.AI.Tools.FilingExtraction.spec().input_schema.required
      iex> "dilution_type" in required and "summary" in required
      true

      iex> dt = LongOrShort.AI.Tools.FilingExtraction.spec().input_schema.properties.dilution_type
      iex> "pipe" in dt.enum and "none" in dt.enum
      true
  """
  @spec spec() :: LongOrShort.AI.Provider.tool_spec()
  def spec do
    %{
      name: "record_filing_extraction",
      description: """
      Record structured dilution facts extracted from an SEC filing. \
      Extract only — do NOT score severity, do NOT provide judgments \
      or recommendations. When a non-required field cannot be \
      determined from the filing text, omit it or return null. \
      Never guess.\
      """,
      input_schema: %{
        type: "object",
        properties: %{
          # ── Categorization ─────────────────────────────────────
          dilution_type: %{
            type: "string",
            enum: @dilution_types,
            description:
              "Primary categorization. Use 'none' for filings that turned out non-dilutive (routine proxies, passive 13-G, etc.)."
          },

          # ── Deal mechanics ─────────────────────────────────────
          deal_size_usd: %{
            type: "number",
            description: "Total deal size in USD. Omit if not disclosed."
          },
          share_count: %{
            type: "integer",
            description:
              "Number of shares being issued or registered. Omit if not disclosed."
          },
          pricing_method: %{
            type: "string",
            enum: @pricing_methods,
            description:
              "How the offering price is set. Use 'unknown' rather than guessing."
          },
          pricing_discount_pct: %{
            type: "number",
            description:
              "Discount from market price as a positive percent (e.g. 10.0 for 10% below). Omit if pricing is fixed or not market-relative."
          },

          # ── Warrants ──────────────────────────────────────────
          warrant_strike: %{
            type: "number",
            description: "Warrant exercise price. Omit if no warrants are part of the deal."
          },
          warrant_term_years: %{
            type: "integer",
            description: "Warrant exercise term in years. Omit if no warrants."
          },

          # ── ATM (at-the-market) program ────────────────────────
          atm_remaining_shares: %{
            type: "integer",
            description:
              "ATM program: shares still available for issuance. Only for ATM filings."
          },
          atm_total_authorized_shares: %{
            type: "integer",
            description:
              "ATM program: total authorized capacity. Only for ATM filings."
          },

          # ── S-3 shelf registration ─────────────────────────────
          shelf_total_authorized_usd: %{
            type: "number",
            description:
              "S-3 shelf total authorized capacity in USD. Only for shelf filings."
          },
          shelf_remaining_usd: %{
            type: "number",
            description:
              "S-3 shelf remaining capacity in USD. Only for shelf filings."
          },

          # ── Convertible instruments ────────────────────────────
          convertible_conversion_price: %{
            type: "number",
            description:
              "Conversion price of any convertible note or preferred stock. Omit if not a convertible deal."
          },

          # ── Governance / structural flags ──────────────────────
          has_anti_dilution_clause: %{
            type: "boolean",
            description:
              "True if the filing discloses an anti-dilution adjustment clause (ratchets, weighted-average, etc.)."
          },
          has_death_spiral_convertible: %{
            type: "boolean",
            description:
              "True if convertible terms include a floating discount-to-market conversion (variable conversion price that worsens as price falls)."
          },
          is_reverse_split_proxy: %{
            type: "boolean",
            description:
              "True if the filing is a DEF 14A proxy seeking shareholder approval for a reverse split."
          },
          reverse_split_ratio: %{
            type: "string",
            description:
              "Reverse split ratio if applicable, e.g. \"1-for-10\". Omit unless this is a reverse split proxy."
          },

          # ── Summary ────────────────────────────────────────────
          summary: %{
            type: "string",
            description:
              "One-line plain-English summary suitable for a UI card. Factual, not editorial — no severity language."
          }
        },
        required:
          ~w(dilution_type pricing_method has_anti_dilution_clause has_death_spiral_convertible is_reverse_split_proxy summary)
      }
    }
  end

  @doc "Valid `dilution_type` enum values, exposed for orchestrator validation."
  @spec dilution_types() :: [String.t()]
  def dilution_types, do: @dilution_types

  @doc "Valid `pricing_method` enum values, exposed for orchestrator validation."
  @spec pricing_methods() :: [String.t()]
  def pricing_methods, do: @pricing_methods
end
