defmodule LongOrShort.Filings.Sources.SecEdgarTest do
  @moduledoc """
  Tests for the SEC EDGAR filings feeder's parser path.

  The HTTP layer is not exercised here (it would require live SEC
  access). Instead, real Atom XML fixtures captured from
  `?action=getcurrent` are committed under `test/fixtures/sec_edgar/`
  and replayed against `SecEdgar.parse_response/1`.

  Coverage targets:

    * Each of the 14 supported form-type fixtures parses as
      well-formed Atom (sanity loop).
    * `parse_response/1` yields the expected attrs shape for at
      least one entry per non-empty fixture.
    * 8-K subtype extraction picks up `"Item N.NN"` from the
      summary HTML; other form types return `nil`.
    * `parse_response/1` surfaces `:no_cik_in_title` and
      `:unmapped_cik` for malformed / unknown filers.
  """

  use LongOrShort.DataCase, async: false

  import SweetXml

  alias LongOrShort.Accounts.SystemActor
  alias LongOrShort.Filings.Sources.SecEdgar
  alias LongOrShort.Tickers

  @fixtures_dir Path.expand("../../../fixtures/sec_edgar", __DIR__)

  @form_types ~w(s1 s1a s3 s3a 424b1 424b2 424b3 424b4 424b5 8k 13d 13g def14a form4)

  # ── helpers ──────────────────────────────────────────────────────

  defp fixture_xml(name), do: File.read!(Path.join(@fixtures_dir, name <> ".xml"))

  # Mirrors the xpath used internally by SecEdgar.parse_entries/1 so
  # tests can drive parse_response/1 with real entry maps without
  # exposing the private function.
  defp entries_from(xml) do
    xml
    |> xpath(~x"//entry"l,
      title: ~x"./title/text()"s,
      link: ~x"./link/@href"s,
      summary: ~x"./summary/text()"s,
      updated: ~x"./updated/text()"s,
      category: ~x"./category/@term"s,
      id: ~x"./id/text()"s
    )
  end

  defp tagged_entries(name, filing_type) do
    name
    |> fixture_xml()
    |> entries_from()
    |> Enum.map(&Map.put(&1, :filing_type, filing_type))
  end

  defp first_entry_with_cik(name, filing_type) do
    name
    |> tagged_entries(filing_type)
    |> Enum.find(fn entry -> Regex.match?(~r/\(\d{10}\)/, entry.title) end)
  end

  defp cik_from_title(title) do
    [_, cik] = Regex.run(~r/\((\d{10})\)/, title)
    cik
  end

  # Uses :upsert_by_symbol because the primary :create action does
  # not accept :cik (CIK is mapped in via the SEC sync worker / feeders
  # which all go through this upsert path).
  defp build_matching_ticker(entry, symbol) do
    cik = cik_from_title(entry.title)

    {:ok, _ticker} =
      Tickers.upsert_ticker_by_symbol(
        %{
          symbol: symbol,
          cik: cik,
          company_name: "Fixture Co for #{symbol}",
          exchange: :nasdaq,
          is_active: true
        },
        actor: SystemActor.new()
      )

    cik
  end

  # ── sanity: every fixture is well-formed Atom ────────────────────

  describe "fixture sanity" do
    for form <- @form_types do
      test "#{form}.xml parses as Atom" do
        entries = unquote(form) |> fixture_xml() |> entries_from()

        # Either we have entries with the expected shape, or the
        # feed is legitimately empty ("No recent filings"). Both are
        # valid Atom outcomes.
        assert is_list(entries)

        for entry <- entries do
          assert is_binary(entry.title) and entry.title != ""
          assert is_binary(entry.id) and entry.id != ""
          assert is_binary(entry.updated) and entry.updated != ""
        end
      end
    end
  end

  # ── parse_response/1 happy path ─────────────────────────────────

  describe "parse_response/1 — happy path" do
    test "8-K entry → attrs with filing_type :_8k and resolved symbol" do
      entry = first_entry_with_cik("8k", :_8k)
      assert entry, "fixture 8k.xml must contain at least one entry with a CIK"

      cik = build_matching_ticker(entry, "EIGHTK")

      assert {:ok, [attrs]} = SecEdgar.parse_response(entry)

      assert attrs.source == :sec_edgar
      assert attrs.filing_type == :_8k
      assert attrs.symbol == "EIGHTK"
      assert attrs.filer_cik == cik
      assert is_binary(attrs.external_id) and attrs.external_id != ""
      assert is_binary(attrs.url) and attrs.url != ""
      assert %DateTime{} = attrs.filed_at
    end

    test "S-1 entry yields :s1 filing_type" do
      entry = first_entry_with_cik("s1", :s1)
      assert entry

      cik = build_matching_ticker(entry, "ESS1")

      assert {:ok, [attrs]} = SecEdgar.parse_response(entry)
      assert attrs.filing_type == :s1
      assert attrs.symbol == "ESS1"
      assert attrs.filer_cik == cik
    end

    test "S-1/A entry yields :s1a filing_type" do
      entry = first_entry_with_cik("s1a", :s1a)
      assert entry

      build_matching_ticker(entry, "ESS1A")

      assert {:ok, [attrs]} = SecEdgar.parse_response(entry)
      assert attrs.filing_type == :s1a
    end

    test "S-3 entry yields :s3 filing_type" do
      entry = first_entry_with_cik("s3", :s3)
      assert entry

      build_matching_ticker(entry, "ESS3")

      assert {:ok, [attrs]} = SecEdgar.parse_response(entry)
      assert attrs.filing_type == :s3
    end

    test "DEF 14A entry yields :def14a filing_type" do
      entry = first_entry_with_cik("def14a", :def14a)
      assert entry

      build_matching_ticker(entry, "EDEF14A")

      assert {:ok, [attrs]} = SecEdgar.parse_response(entry)
      assert attrs.filing_type == :def14a
    end

    test "Form 4 entry yields :form4 filing_type" do
      entry = first_entry_with_cik("form4", :form4)
      assert entry

      build_matching_ticker(entry, "EFRM4")

      assert {:ok, [attrs]} = SecEdgar.parse_response(entry)
      assert attrs.filing_type == :form4
    end
  end

  # ── parse_response/1 subtype extraction ──────────────────────────

  describe "parse_response/1 — subtype extraction" do
    test "8-K extracts first 'Item N.NN' from summary as filing_subtype" do
      entry = first_entry_with_cik("8k", :_8k)
      assert entry

      # Sanity: real 8-K fixture entries always carry an Item N.NN
      # marker in the summary HTML body.
      assert Regex.match?(~r/Item\s+\d+\.\d+/, entry.summary)

      build_matching_ticker(entry, "EIGHTKSUB")

      assert {:ok, [attrs]} = SecEdgar.parse_response(entry)
      assert attrs.filing_subtype =~ ~r/^Item \d+\.\d+$/
    end

    test "non-8-K filings return nil filing_subtype" do
      entry = first_entry_with_cik("s1", :s1)
      assert entry

      build_matching_ticker(entry, "ENOSUB")

      assert {:ok, [attrs]} = SecEdgar.parse_response(entry)
      assert attrs.filing_subtype == nil
    end

    test "8-K with no Item marker in summary yields nil filing_subtype" do
      # Synthesize an 8-K-like entry without any Item line. Reuse a
      # real fixture entry but blank the summary so we exercise the
      # 'no Item match' branch deterministically.
      entry =
        "8k"
        |> first_entry_with_cik(:_8k)
        |> Map.put(:summary, "No item lines here")

      build_matching_ticker(entry, "ENOITEM")

      assert {:ok, [attrs]} = SecEdgar.parse_response(entry)
      assert attrs.filing_subtype == nil
    end
  end

  # ── parse_response/1 error paths ────────────────────────────────

  describe "parse_response/1 — errors" do
    test "returns :no_cik_in_title when title is missing the (NNNNNNNNNN) tag" do
      entry = %{
        title: "8-K - SOME COMPANY (Filer)",
        link: "https://example.com/x",
        summary: "irrelevant",
        updated: "2026-05-08T10:00:00-04:00",
        category: "8-K",
        id: "urn:tag:sec.gov,2008:accession-number=fake",
        filing_type: :_8k
      }

      assert {:error, :no_cik_in_title} = SecEdgar.parse_response(entry)
    end

    test "returns :unmapped_cik when no Ticker matches the extracted CIK" do
      # Use a real entry shape but DO NOT seed a matching ticker.
      entry = first_entry_with_cik("8k", :_8k)
      assert entry

      assert {:error, :unmapped_cik} = SecEdgar.parse_response(entry)
    end
  end

  # ── source_name / poll_interval_ms / cursor identity ─────────────

  describe "behaviour callbacks" do
    test "source_name/0 is :sec_filings (distinct from News.Sources.SecEdgar's :sec)" do
      assert SecEdgar.source_name() == :sec_filings
    end

    test "poll_interval_ms/0 is 60_000 (60s)" do
      assert SecEdgar.poll_interval_ms() == 60_000
    end
  end
end
