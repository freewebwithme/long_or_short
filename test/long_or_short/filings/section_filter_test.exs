defmodule LongOrShort.Filings.SectionFilterTest do
  @moduledoc """
  Tests for `LongOrShort.Filings.SectionFilter`.

  Synthetic fixtures kept inline as module attributes — real SEC
  filings are tens of KB; the regex contract only needs short
  representative samples to exercise.
  """

  use ExUnit.Case, async: true

  alias LongOrShort.Filings.SectionFilter

  # ── Fixtures ───────────────────────────────────────────────────

  @s1_sample """
  Table of Contents
  Some preamble text and introductory matter.

  USE OF PROCEEDS

  We intend to use the net proceeds for general corporate purposes
  and working capital.

  DILUTION

  Investors purchasing shares in this offering will experience
  immediate dilution of $1.00 per share.

  PLAN OF DISTRIBUTION

  The shares will be sold via a firm commitment underwriting.

  DESCRIPTION OF CAPITAL STOCK

  Our authorized capital stock consists of 100,000,000 shares.
  """

  @s1_no_headers """
  This document has no recognizable section headers and exists to
  exercise the fallback-to-full-text path.
  """

  @item_3_02_sample """
  Item 1.01 - Entry into Material Definitive Agreement

  Some unrelated agreement details.

  Item 3.02 - Unregistered Sales of Equity Securities

  On May 1, 2026, the Company entered into a PIPE agreement to
  issue 1,000,000 shares at $5.00 per share.

  Item 9.01 - Financial Statements and Exhibits

  Exhibit 99.1 attached.
  """

  @def14a_with_reverse """
  Notice of Annual Meeting of Stockholders.

  The Board recommends a vote FOR Proposal 3 to authorize a
  reverse stock split at a ratio of 1-for-10.
  """

  @def14a_routine """
  Notice of Annual Meeting of Stockholders.

  Proposal 1: Election of directors.
  Proposal 2: Ratification of auditors.
  """

  @schedule_13d """
  SCHEDULE 13D
  Item 1. Security and Issuer.
  Item 2. Identity and Background.
  The Reporting Person has acquired beneficial ownership of 6.2%.
  """

  # ── Form 4 explicitly unsupported ──────────────────────────────

  describe "Form 4" do
    test "returns :not_supported" do
      assert {:error, :not_supported} = SectionFilter.filter("anything", :form4)
    end
  end

  # ── Prospectus types ───────────────────────────────────────────

  describe "prospectus types" do
    @prospectus_types ~w(s1 s1a s3 s3a _424b1 _424b2 _424b3 _424b4 _424b5)a

    test "extracts named sections from a well-structured prospectus" do
      for type <- @prospectus_types do
        {:ok, sections} = SectionFilter.filter(@s1_sample, type)

        names = Enum.map(sections, fn {name, _body} -> name end)

        assert "USE OF PROCEEDS" in names,
               "missing USE OF PROCEEDS for #{type}: got #{inspect(names)}"

        assert "DILUTION" in names,
               "missing DILUTION for #{type}: got #{inspect(names)}"

        # Section bodies are non-empty
        for {_name, body} <- sections, do: assert(String.trim(body) != "")
      end
    end

    test "drops the preamble (text before the first header)" do
      {:ok, sections} = SectionFilter.filter(@s1_sample, :s1)
      first_body = sections |> List.first() |> elem(1)

      refute String.contains?(first_body, "Table of Contents"),
             "preamble should be dropped, not included in first section body"
    end

    test "falls back to full text when no headers are found" do
      assert {:ok, [{:full_text, full}]} = SectionFilter.filter(@s1_no_headers, :s1)
      assert full == @s1_no_headers
    end
  end

  # ── Header dedup (LON-164) ─────────────────────────────────────

  describe "prospectus dedup" do
    # Real SEC prospectuses emit the same header name multiple times:
    # once in the TOC ("RISK FACTORS ........ 17"), once at the actual
    # section, sometimes again as a cross-reference. The lookahead-split
    # regex creates a chunk per occurrence — dedup keeps the real
    # section body (largest above the min-real-body threshold).

    @real_body_padding String.duplicate("real body content. ", 50)

    test "keeps only the largest chunk per header when TOC entries duplicate" do
      # Two RISK FACTORS occurrences: tiny TOC entry + sizable real body.
      # In a real document the TOC entry chunk extends to the next TOC
      # header — here we simulate that with a short slice followed by
      # the actual section.
      text = """
      Table of Contents
      RISK FACTORS
      Page 17

      USE OF PROCEEDS
      Page 20

      RISK FACTORS
      #{@real_body_padding}
      The company faces material dilution risks from outstanding warrants.

      USE OF PROCEEDS
      Net proceeds will fund working capital.
      """

      {:ok, sections} = SectionFilter.filter(text, :s1)

      # One entry per unique header — no duplicates
      header_names = Enum.map(sections, fn {n, _} -> n end)
      assert length(header_names) == length(Enum.uniq(header_names))

      # The RISK FACTORS body we keep is the one with the padding,
      # not the bare "Page 17" TOC slice
      {_, risk_body} = Enum.find(sections, fn {n, _} -> String.upcase(n) == "RISK FACTORS" end)
      assert risk_body =~ "real body content"
      assert risk_body =~ "outstanding warrants"
    end

    test "keeps at least the largest chunk even when all are short (no real body)" do
      # Pathological: prospectus body got cut off, only TOC remains.
      # We should still surface something rather than drop the section.
      text = """
      Table of Contents
      RISK FACTORS
      Page 17

      DILUTION
      Page 19
      """

      {:ok, sections} = SectionFilter.filter(text, :s1)

      # Both sections kept (largest-fallback path), even though they're
      # tiny — better to show TOC slices than to silently lose data
      header_names = Enum.map(sections, fn {n, _} -> String.upcase(n) end)
      assert "RISK FACTORS" in header_names
      assert "DILUTION" in header_names
    end

    test "preserves first-occurrence order across sections" do
      # USE OF PROCEEDS appears before RISK FACTORS in this filing.
      # Even though RISK FACTORS gets a bigger body, its place in the
      # output list reflects where the section first showed up.
      text = """
      USE OF PROCEEDS
      #{@real_body_padding}
      Working capital and general corporate purposes.

      RISK FACTORS
      #{@real_body_padding}
      #{@real_body_padding}
      Dilution risk from outstanding warrants and convertibles.
      """

      {:ok, sections} = SectionFilter.filter(text, :s1)

      [{first_name, _} | _] = sections
      assert String.upcase(first_name) == "USE OF PROCEEDS"
    end
  end

  # ── 8-K item extraction ────────────────────────────────────────

  describe "8-K with filing_subtype" do
    test "extracts only the named Item body" do
      {:ok, [{name, body}]} =
        SectionFilter.filter(@item_3_02_sample, :_8k, filing_subtype: "8-K Item 3.02")

      assert name == "Item 3.02"
      assert body =~ "PIPE agreement"

      # Body stops before the next Item header
      refute body =~ "Item 9.01",
             "extraction should not bleed into the next Item: #{inspect(body)}"

      # And does not include the earlier Item
      refute body =~ "Material Definitive Agreement",
             "extraction should not include the earlier Item"
    end

    test "falls back to full text when subtype hint is missing" do
      assert {:ok, [{:full_text, full}]} =
               SectionFilter.filter(@item_3_02_sample, :_8k)

      assert full == @item_3_02_sample
    end

    test "falls back to full text when target Item isn't present" do
      assert {:ok, [{:full_text, _}]} =
               SectionFilter.filter(@item_3_02_sample, :_8k,
                 filing_subtype: "8-K Item 5.07"
               )
    end
  end

  # ── DEF 14A keyword filter ─────────────────────────────────────

  describe "DEF 14A" do
    test "returns full text when a dilution-precursor keyword is present" do
      assert {:ok, [{:full_text, full}]} =
               SectionFilter.filter(@def14a_with_reverse, :def14a)

      assert full == @def14a_with_reverse
    end

    test "returns empty list when no keywords are present (skip the LLM)" do
      assert {:ok, []} = SectionFilter.filter(@def14a_routine, :def14a)
    end

    test "is case-insensitive on keywords" do
      uppercased = String.upcase(@def14a_with_reverse)
      assert {:ok, [{:full_text, _}]} = SectionFilter.filter(uppercased, :def14a)
    end
  end

  # ── 13-D / 13-G return whole body ─────────────────────────────

  describe "13-D / 13-G" do
    test "returns full text without filtering for both types" do
      for type <- [:_13d, :_13g] do
        assert {:ok, [{:full_text, full}]} = SectionFilter.filter(@schedule_13d, type)
        assert full == @schedule_13d
      end
    end
  end

  # ── max_section_chars option (LON-119) ─────────────────────────

  describe "max_section_chars option" do
    test "without the option, full body is returned" do
      {:ok, sections} = SectionFilter.filter(@s1_sample, :s1)

      for {_name, body} <- sections do
        refute body =~ "[... truncated]"
      end
    end

    test "caps each section body at the requested length" do
      long_body = String.duplicate("dilution language. ", 1000)

      sample = """
      Preamble.

      USE OF PROCEEDS

      #{long_body}
      """

      {:ok, sections} = SectionFilter.filter(sample, :s1, max_section_chars: 100)
      {_name, body} = List.first(sections)

      # 100-char cap + ~16-char truncation marker
      assert String.length(body) <= 200
      assert body =~ "[... truncated]"
      assert body =~ "dilution language"
    end

    test "passes through bodies shorter than the cap untouched" do
      {:ok, sections} = SectionFilter.filter(@s1_sample, :s1, max_section_chars: 10_000)

      for {_name, body} <- sections do
        refute body =~ "[... truncated]"
      end
    end

    test "applies to :full_text fallback" do
      long_text = String.duplicate("ATM details. ", 1000)
      sample = "ATM offering disclosure: " <> long_text

      {:ok, [{:full_text, body}]} =
        SectionFilter.filter(sample, :s1, max_section_chars: 100)

      assert String.length(body) <= 200
      assert body =~ "[... truncated]"
    end

    test "does not affect error returns (Form 4)" do
      assert {:error, :not_supported} =
               SectionFilter.filter("any", :form4, max_section_chars: 100)
    end
  end
end
