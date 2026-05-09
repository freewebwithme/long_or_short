defmodule LongOrShort.Filings.SectionFilter do
  @moduledoc """
  Pre-LLM section extraction for `LongOrShort.Filings.Filing` raw text.

  Reduces a typical 25K-token S-1 to a few thousand tokens of dilution-
  relevant content before the LLM extraction pass. The per-filing-type
  policy is explained in the glossary below.

  ## Output contract

      {:ok, [{name :: String.t() | :full_text, body :: String.t()}]}
      {:ok, []}                         # nothing dilution-relevant — skip LLM
      {:error, :not_supported}          # Form 4 etc.

  Callers (`LongOrShort.Filings.Extractor`) treat `{:ok, []}` as a
  signal to short-circuit before the LLM call.

  ## Fallback policy

  When the prospectus regex cannot find any section headers, the full
  raw text is returned. False negatives on the filter are worse than
  paying for extra tokens — better to over-include than miss data.

  ─────────────────────────────────────────────────────────────────────

  ## SEC filing-type glossary

  Every form below is filed with the SEC and is part of the dilution
  signal pipeline (LON-106 epic). Numbers like "424B" follow SEC
  convention — they are not arbitrary.

  ### Prospectuses (registration of new shares)

    * **S-1 / S-1/A** — Initial registration statement for new equity.
      The "/A" suffix means "amendment" (revised pricing, updated
      share count, etc.). Filed when a company wants to sell new
      shares to the public for the first time or for a follow-on
      offering. Direct dilution signal.

    * **S-3 / S-3/A** — Simplified registration available only to
      established issuers that meet certain reporting and float
      criteria. Frequently used as a *shelf* — register a large
      capacity up front, then issue tranches whenever needed.
      Existence of an active S-3 is a forward-looking dilution risk.

    * **424B1–424B5** — *Final* prospectus filings made after the
      registration above is declared effective. The trailing digit
      identifies the takedown context:
        - 424B1 — initial public offering
        - 424B2 — shelf takedown (most common for follow-ons)
        - 424B3 — substantive post-effective changes
        - 424B4 — terms differ from the registration statement
        - 424B5 — debt or equity shelf takedown
      A 424B is the "this is happening now" signal — the offering
      is priced and being sold.

  ### Other forms

    * **8-K** — "Current report" for material events. Each event is
      tagged by an Item number; the dilution-relevant ones are:
        - Item 1.01 — Entry into a Material Definitive Agreement
          (offering / underwriting agreements live here)
        - Item 3.02 — Unregistered Sales of Equity Securities
          (PIPE deals — directly dilutive)
      `filing_subtype` (e.g. "8-K Item 3.02") lets us scope
      extraction to just the relevant Item body.

    * **DEF 14A** — Definitive proxy statement, filed before a
      shareholder vote. Most proxies are routine (election of
      directors); a small fraction propose actions that change the
      share structure — see the keyword list below.

    * **13-D / 13-G** — Beneficial-ownership reports filed when an
      investor crosses 5%. 13-D is for active stakeholders (intent
      to influence); 13-G is for passive holders. Short documents,
      no section pre-filter needed — the LLM reads the whole body.

    * **Form 4** — Insider transaction report (officers, directors,
      10%+ holders). Has its own structured XML pipeline in Stage 9
      (LON-118), so this module returns `{:error, :not_supported}`.

  ## Prospectus section glossary

  The strings in `@prospectus_sections` are SEC-standard headings
  that appear verbatim in nearly every prospectus. Why each matters
  for dilution analysis:

    * **USE OF PROCEEDS** — How the company will spend the money
      raised. "General working capital" reads bearishly; "specific
      acquisition" or "debt repayment" reads better.

    * **DILUTION** — The explicit, quantified disclosure of
      per-share dilution to existing holders. The most directly
      relevant section.

    * **PLAN OF DISTRIBUTION** — Sales mechanics: firm commitment
      underwriting (one-shot block), best-efforts, or at-the-market
      (ATM, drips into the market continuously). Affects expected
      price impact timing.

    * **DESCRIPTION OF SECURITIES / DESCRIPTION OF CAPITAL STOCK** —
      Rights and structure of what is being sold. Warrant terms,
      conversion features, anti-dilution clauses, and death-spiral
      convertible terms are disclosed here.

    * **RISK FACTORS** — Mostly boilerplate, but specific dilution
      warnings (e.g. "we may issue additional shares without
      notice") sometimes appear here and elsewhere they don't.

  Companies generally emit both "DESCRIPTION OF SECURITIES" and
  "DESCRIPTION OF CAPITAL STOCK" as variants of the same idea — we
  match either.

  ## DEF 14A keyword glossary

  These are the dilution-precursor proposals worth flagging in an
  otherwise routine proxy. If none appear, the proxy is almost
  certainly non-dilutive and we skip the LLM call entirely.

    * **"reverse stock split" / "reverse split"** — A vote to
      compress the share count (e.g. 1-for-10). Frequently a
      precursor to either a Nasdaq listing-cure or a fresh dilution
      round; almost always bearish for small caps.

    * **"increase in authorized shares" / "authorized capital"** —
      A vote to raise the company's authorized (not yet issued)
      share ceiling. Doesn't dilute today, but creates the
      *capacity* for large future issuance — read as forward-looking
      dilution headroom.

    * **"share authorization"** — Catches less-standard phrasings
      of the same concept (e.g. "Proposal to authorize additional
      shares of common stock").
  """

  @typedoc "Either a named section or the full text fallback."
  @type section :: {name :: String.t() | :full_text, body :: String.t()}

  # SEC prospectus and final-prospectus form types. See the
  # "Prospectuses" subsection of the moduledoc glossary.
  @prospectus_types ~w(s1 s1a s3 s3a _424b1 _424b2 _424b3 _424b4 _424b5)a

  # SEC-standard prospectus section headings to extract. See the
  # "Prospectus section glossary" subsection of the moduledoc for
  # what each section discloses and why it matters.
  @prospectus_sections [
    "USE OF PROCEEDS",
    "DILUTION",
    "PLAN OF DISTRIBUTION",
    "DESCRIPTION OF SECURITIES",
    "DESCRIPTION OF CAPITAL STOCK",
    "RISK FACTORS"
  ]

  # Substrings whose presence in a DEF 14A proxy signals a
  # dilution-precursor proposal worth analyzing. See the
  # "DEF 14A keyword glossary" subsection of the moduledoc.
  @def14a_keywords [
    "reverse stock split",
    "reverse split",
    "increase in authorized shares",
    "authorized capital",
    "share authorization"
  ]

  @doc """
  Extract dilution-relevant sections from a filing's raw text.

  ## Options

    * `:filing_subtype` — for 8-K filings, the subtype string (e.g.
      "8-K Item 3.02") used to scope extraction to a single Item.
  """
  @spec filter(String.t(), atom(), keyword()) ::
          {:ok, [section()]} | {:error, :not_supported}
  def filter(raw_text, filing_type, opts \\ [])

  def filter(_raw_text, :form4, _opts), do: {:error, :not_supported}

  def filter(raw_text, filing_type, _opts) when filing_type in @prospectus_types do
    {:ok, prospectus_sections(raw_text)}
  end

  def filter(raw_text, :_8k, opts) do
    case Keyword.get(opts, :filing_subtype) do
      nil -> {:ok, [{:full_text, raw_text}]}
      subtype when is_binary(subtype) -> {:ok, item_section(raw_text, subtype)}
    end
  end

  def filter(raw_text, :def14a, _opts) do
    if has_def14a_keywords?(raw_text) do
      {:ok, [{:full_text, raw_text}]}
    else
      {:ok, []}
    end
  end

  def filter(raw_text, ft, _opts) when ft in [:_13d, :_13g] do
    {:ok, [{:full_text, raw_text}]}
  end

  # ── Prospectus section extraction ──────────────────────────────

  defp prospectus_sections(raw_text) do
    headers_pattern = Enum.map_join(@prospectus_sections, "|", &Regex.escape/1)
    # Lookahead split — keeps the header attached to the body that
    # follows it. The first chunk (before any header) is the
    # preamble / TOC and gets dropped.
    splitter = Regex.compile!("(?=^\\s*(?:#{headers_pattern})\\s*$)", "im")

    case Regex.split(splitter, raw_text, parts: :infinity) do
      [_preamble_only] ->
        [{:full_text, raw_text}]

      [_preamble | sections] ->
        sections
        |> Enum.map(&split_header_and_body/1)
        |> Enum.reject(fn {_name, body} -> String.trim(body) == "" end)
        |> case do
          [] -> [{:full_text, raw_text}]
          pairs -> pairs
        end
    end
  end

  defp split_header_and_body(chunk) do
    case String.split(chunk, "\n", parts: 2) do
      [header_line] -> {String.trim(header_line), ""}
      [header_line, body] -> {String.trim(header_line), body}
    end
  end

  # ── 8-K Item extraction ────────────────────────────────────────

  defp item_section(raw_text, subtype) do
    case extract_item_number(subtype) do
      nil ->
        [{:full_text, raw_text}]

      item_num ->
        target_pattern = Regex.compile!("(?=^\\s*Item\\s+#{Regex.escape(item_num)}\\b)", "im")

        # Lookahead splits land on the \n preceding the matched line, so
        # `after_target` arrives with leading whitespace — trim it before
        # peeling off the header line.
        with [_preamble, after_target] <- Regex.split(target_pattern, raw_text, parts: 2),
             trimmed = String.trim_leading(after_target),
             [_target_header, rest] <- String.split(trimmed, "\n", parts: 2) do
          # `next_header` would also match our own header; we already
          # peeled it off above, so splitting `rest` on the next header
          # yields the body cleanly.
          next_header = ~r/^\s*Item\s+\d+\.\d+/im
          [body | _] = String.split(rest, next_header, parts: 2)
          [{"Item #{item_num}", body}]
        else
          _ -> [{:full_text, raw_text}]
        end
    end
  end

  # subtype examples: "8-K Item 3.02", "Item 1.01", "Item 3.02 - Material Agreement"
  defp extract_item_number(subtype) do
    case Regex.run(~r/Item\s+(\d+\.\d+)/i, subtype) do
      [_, num] -> num
      nil -> nil
    end
  end

  # ── DEF 14A keyword filter ─────────────────────────────────────

  defp has_def14a_keywords?(raw_text) do
    text = String.downcase(raw_text)
    Enum.any?(@def14a_keywords, &String.contains?(text, &1))
  end
end
