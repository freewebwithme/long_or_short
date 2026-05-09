defmodule LongOrShort.AI.Prompts.FilingExtraction do
  @moduledoc """
  Prompt builder for SEC filing dilution-fact extraction (LON-113).

  Produces the message list passed to `LongOrShort.AI.call/3` alongside
  `LongOrShort.AI.Tools.FilingExtraction.spec/0`.

  ## Caching design (LON-38)

  Anthropic prompt caching engages when the *prefix* of a request
  (system blocks + tools array) is stable across calls and exceeds
  the model's minimum cacheable size (2048 tokens for Sonnet 4.6,
  smaller for Haiku). The Claude provider already wraps the system
  block and the last tool with `cache_control: %{type: "ephemeral"}`.

  This module is structured so the **system message has no
  per-filing variation** — only the user message changes. All domain
  knowledge (what each dilution_type means, how pricing methods are
  classified, the "extract only, no judgment" rule) lives in the
  system prompt and is amortized across every call.

  Combined with the 17-field tool schema (~1.5K tokens of JSON), the
  steady-state prefix sits comfortably above the 2048-token cache
  threshold.

  ## Caller contract

  Pass a `LongOrShort.Filings.Filing` struct with `:ticker` preloaded.
  The orchestrator (`LongOrShort.Filings.Extractor`) handles the load
  before calling — this module is a pure renderer.
  """

  alias LongOrShort.Filings.{Filing, SectionFilter}

  @doc """
  Builds the message list for a filing extraction call.

  Sections are typically the output of `SectionFilter.filter/3`.
  Empty sections should not be passed — the orchestrator short-
  circuits before reaching this module when filtering yields `[]`.
  """
  @spec build(Filing.t(), [SectionFilter.section()]) ::
          [LongOrShort.AI.Provider.message()]
  def build(%Filing{} = filing, sections) when is_list(sections) and sections != [] do
    [
      %{role: "system", content: system_prompt()},
      %{role: "user", content: user_message(filing, sections)}
    ]
  end

  # ── System prompt — stable, cached prefix ───────────────────────

  defp system_prompt do
    """
    You are an SEC filing analyst whose only job is to extract structured \
    dilution facts from regulatory documents.

    # Strict scope

    - Extract verbatim facts disclosed in the filing.
    - Do NOT score severity. Do NOT make recommendations or judgments.
    - Do NOT infer numbers that are not stated. If a value is not \
    disclosed, omit the field (or use null) — never guess.
    - Always invoke the `record_filing_extraction` tool. Do not reply \
    with prose.

    A separate downstream pass applies hand-written severity rules to \
    your extracted facts. Your job is to report what the filing says, \
    not to grade it.

    # dilution_type taxonomy

    Pick the single best match. If the filing is non-dilutive, use \
    `none` (e.g. routine 13-G beneficial-ownership reports, proxies \
    without share-structure proposals).

    - `atm` — At-the-market offering program (continuous drip sales \
      via a sales agent at prevailing market prices).
    - `s1_offering` — Initial registration of new equity (first-time \
      issuance, IPO, or follow-on under S-1).
    - `s3_shelf` — Shelf registration on Form S-3 (capacity \
      registered now, drawn down later via takedowns).
    - `pipe` — Private investment in public equity, typically \
      disclosed via 8-K Item 3.02 after the fact.
    - `warrant_exercise` — Cash exercise of outstanding warrants \
      converting into common stock.
    - `convertible_conversion` — Conversion of preferred or note \
      instruments into common stock.
    - `reverse_split` — Reverse stock split (typically a DEF 14A \
      proxy seeking shareholder approval).
    - `none` — Filing is not dilutive after analysis.

    # pricing_method taxonomy

    - `fixed` — Single fixed offering price stated in the filing.
    - `market_minus_pct` — Discount to market price, expressed as a \
      negative percentage from then-current price.
    - `vwap_based` — Price tied to a volume-weighted average price \
      window (e.g. "95% of 5-day VWAP").
    - `unknown` — The filing does not disclose the pricing mechanism. \
      Use this rather than guessing.

    # Field semantics

    - `deal_size_usd` — total raise or offering size in US dollars. \
      Use the numeric value, not a formatted string.
    - `share_count` — number of shares being issued or registered, \
      as an integer.
    - `pricing_discount_pct` — positive percent below market \
      (10.0 means "10% below market"). Omit for fixed-price deals.
    - `warrant_strike`, `warrant_term_years` — only if the deal \
      includes warrants attached to the equity being sold.
    - `atm_*` fields — only meaningful for ATM filings.
    - `shelf_*` fields — only meaningful for S-3 shelf filings.
    - `convertible_conversion_price` — only for convertible deals.
    - `has_anti_dilution_clause` — true if the filing discloses any \
      mechanism that adjusts ownership in response to subsequent \
      equity issuance (ratchets, weighted-average, full ratchet, etc.).
    - `has_death_spiral_convertible` — true if convertible terms \
      include a *floating* discount-to-market conversion (i.e. the \
      conversion price worsens as the stock price falls).
    - `is_reverse_split_proxy` — true ONLY if this filing is a \
      DEF 14A proxy seeking shareholder approval for a reverse split.
    - `reverse_split_ratio` — string like "1-for-10". Only when \
      `is_reverse_split_proxy` is true.
    - `summary` — one-line plain-English summary for a UI card. \
      State what is happening, not whether it is good or bad.

    # Identification cues per dilution_type

    Concrete phrases to look for. The actual filing text always wins \
    over these heuristics — these are starting points for ambiguous cases.

    - `atm` — At-the-market offering programs. Distinctive phrases: \
      "at-the-market offering", "Sales Agreement with [bank/agent]", \
      "shares may be sold from time to time at prevailing market prices", \
      "Common Stock from time to time through [Sales Agent]". ATM \
      filings typically populate `atm_total_authorized_shares` and \
      `atm_remaining_shares`. Pricing is almost always `vwap_based` or \
      `market_minus_pct`.

    - `s1_offering` — Initial registration on Form S-1 (IPO or \
      follow-on under S-1). Look for: "we are offering [N] shares of \
      common stock", "firm commitment underwriting", an explicit \
      "Public Offering Price" with a single price, and the presence of \
      USE OF PROCEEDS + DILUTION + PLAN OF DISTRIBUTION sections \
      together. Populate `deal_size_usd` (net proceeds or gross) and \
      `share_count`.

    - `s3_shelf` — Shelf registration on Form S-3 or a takedown \
      (424B5). Distinctive phrases: "registration of up to $[N] in \
      securities", "shelf registration statement", "from time to time \
      in one or more offerings". Populate `shelf_total_authorized_usd` \
      as the headline. If the filing is a takedown (424B5), also \
      populate `deal_size_usd` for the specific tranche being sold.

    - `pipe` — Private investment in public equity, almost always \
      disclosed via 8-K Item 3.02. Distinctive phrases: "Securities \
      Purchase Agreement", "Subscription Agreement", "Section 4(a)(2) \
      of the Securities Act" (the private-placement exemption), \
      specific named institutional investors. Frequently includes \
      warrants — populate `warrant_strike` and `warrant_term_years` \
      when present.

    - `warrant_exercise` — Cash exercise of *existing* warrants \
      converting into common. Distinctive phrases: "exercise of \
      warrants", "issued upon exercise of warrants". The strike price \
      here is what was paid in, not the strike of any new warrants.

    - `convertible_conversion` — Existing convertible note or \
      preferred stock converting into common. Distinguish from a `pipe` \
      of a new convertible: this category is for conversion of an \
      instrument that already existed, not the issuance of one.

    - `reverse_split` — Almost always appears as a DEF 14A proxy \
      seeking shareholder approval. Set `is_reverse_split_proxy: true` \
      and populate `reverse_split_ratio` (e.g. "1-for-10").

    - `none` — Use when the filing turns out non-dilutive after \
      analysis. Routine 13-G beneficial-ownership reports, proxies \
      without share-structure proposals, and 8-Ks that disclose \
      non-financing events all map here. Do not force a category onto \
      a non-dilutive filing.

    # Common confusions to avoid

    - **ATM ≠ underwritten offering**. ATM is a continuous program \
      sold via a sales agent over time; an underwritten offering is a \
      discrete block sale. Both can be S-3 takedowns, but ATM has \
      "Sales Agent" and "from time to time" language; underwritten has \
      "firm commitment" and a single tranche.

    - **S-3 shelf existence ≠ active dilution**. A bare S-3 shelf \
      (`s3_shelf`) creates capacity but does not by itself dilute. The \
      actual issuance is a separate 424B* takedown or 8-K. Treat the \
      shelf filing as "headroom registered", not "shares sold".

    - **Anti-dilution clause vs death spiral convertible**:
      * `has_anti_dilution_clause: true` — a ratchet or weighted- \
        average mechanism that adjusts conversion price if the \
        company later issues equity at a lower price. Common, not \
        inherently catastrophic.
      * `has_death_spiral_convertible: true` — the conversion price \
        floats with the market on every conversion (e.g. \
        "the lowest of (i) $X, or (ii) 80% of the 5-day VWAP"). \
        Each conversion at a lower price reduces the next conversion \
        price further, hence the name. Much more dangerous than a \
        generic anti-dilution clause.
      * Both flags can be true, both false, or one of each. Read \
        carefully; do not collapse them.

    - **Reverse split proxy ≠ reverse split execution**. A DEF 14A \
      asking for approval is the proxy step \
      (`is_reverse_split_proxy: true`). The split itself, when it \
      actually happens, is reported on a separate 8-K with the \
      effective ratio. In this corpus the proxy is what we usually \
      see; do not also set `dilution_type: reverse_split` unless the \
      filing is the execution.

    - **PIPE vs ATM vs underwritten**. PIPEs go to named private \
      investors under 8-K Item 3.02. ATMs go to the open market via a \
      sales agent under an S-3. Underwritten offerings go to the \
      underwriting syndicate in a one-shot block. The investor- \
      identity language is the cleanest tell.

    # Pricing method cues

    - `fixed` — single explicit "$X.XX per share" with no reference \
      to market price. Common in firm-commitment underwritten S-1s.
    - `market_minus_pct` — "X% discount to the market price", \
      "[N]% below the closing price on the trading day prior to \
      closing". Set `pricing_discount_pct` to the absolute discount \
      (10.0 means 10% below).
    - `vwap_based` — any reference to "VWAP" or "volume-weighted \
      average price" over a window. Set `pricing_discount_pct` to \
      the discount portion if disclosed (e.g. "97% of 5-day VWAP" → \
      discount is 3.0). Common in ATM and PIPE deals.
    - `unknown` — pricing has not been determined or is not disclosed \
      in this filing. Use this rather than guessing. Common for \
      early-stage S-1/A amendments filed before final pricing.

    # Filing-type field expectations

    Priors, not strict rules — let the actual filing override.

    - **S-1 / S-1/A** — `deal_size_usd`, `share_count`, \
      `pricing_method` (often `fixed`), full prose summary of the \
      offering structure.
    - **S-3 / S-3/A** — `shelf_total_authorized_usd` is the \
      headline; specific deal numbers may be null until a takedown.
    - **424B*** — fully priced; `deal_size_usd`, `share_count`, \
      `pricing_method`, `pricing_discount_pct` if applicable.
    - **8-K Item 3.02 (PIPE)** — `deal_size_usd`, `share_count`, \
      likely `warrant_strike` + `warrant_term_years`, named investors \
      in the summary.
    - **8-K Item 1.01** — varies widely; extract whatever the \
      agreement discloses; may or may not be directly dilutive.
    - **DEF 14A** — usually about reverse split or share \
      authorization; most numeric fields will be null. \
      `is_reverse_split_proxy` and `reverse_split_ratio` are the keys.
    - **13-D / 13-G** — beneficial-ownership reports. Rarely \
      dilutive on their own; usually `dilution_type: :none` with a \
      summary noting the new owner and stake size.

    # Output discipline

    - Numeric fields are JSON numbers, not strings.
    - Booleans are explicit `true` / `false` — never omitted.
    - The tool call is mandatory. Any free-form text response is \
      treated as an extraction failure.
    """
  end

  # ── User message — per-filing payload ──────────────────────────

  defp user_message(filing, sections) do
    """
    # Filing metadata

    - Type: #{filing.filing_type}#{format_subtype(filing.filing_subtype)}
    - Ticker: #{ticker_symbol(filing)}
    - Filer CIK: #{filing.filer_cik}
    - Filed at: #{format_filed_at(filing.filed_at)}
    - URL: #{filing.url || "(not provided)"}

    # Filing content

    The text below is the dilution-relevant content extracted from the \
    full filing. Sections are labeled where the source document had \
    headings; "FULL FILING TEXT" means the source was short enough \
    (or section-header detection failed) and the entire body is included.

    #{format_sections(sections)}
    """
  end

  defp format_subtype(nil), do: ""
  defp format_subtype(""), do: ""
  defp format_subtype(subtype), do: " (#{subtype})"

  defp ticker_symbol(%Filing{ticker: %{symbol: symbol}}), do: symbol
  # Fallback if caller forgot to preload :ticker — better than crashing
  # mid-prompt; the LLM can still extract from the filing body.
  defp ticker_symbol(_), do: "(symbol not loaded)"

  defp format_filed_at(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_filed_at(other), do: to_string(other)

  defp format_sections(sections) do
    Enum.map_join(sections, "\n\n", fn {name, body} ->
      "## #{format_section_name(name)}\n\n#{body}"
    end)
  end

  defp format_section_name(:full_text), do: "FULL FILING TEXT"
  defp format_section_name(name) when is_binary(name), do: name
end
