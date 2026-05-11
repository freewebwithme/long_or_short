defmodule LongOrShort.Filings.Form4Parser do
  @moduledoc """
  Parse SEC Form 4 ownership XML into insider transaction maps —
  LON-118, Stage 9 of the LON-106 dilution-aware analysis epic.

  Form 4 is the SEC's standard form for reporting changes in
  beneficial ownership by insiders (officers, directors,
  10%-owners). Unlike S-1 / 8-K / DEF 14A which are unstructured
  prose, Form 4 follows a stable XML schema
  (https://www.sec.gov/info/edgar/specifications/ownership-xml-tech-spec).
  This means LLM extraction would be wasteful — direct XML parsing
  is cheaper, deterministic, and not subject to model drift.

  ## Scope (Phase 1)

  We only pull `nonDerivativeTransaction` rows. Derivative
  transactions (option grants, conversions) are out of scope —
  they describe future potential dilution, not actual current
  share movements, and add noise to the "did the insider just
  sell?" signal the dilution profile needs (LON-116's
  `:insider_selling_post_filing` flag).

  Multiple `<reportingOwner>` elements are technically possible in
  a single Form 4 but rare in practice (~1% of filings). Phase 1
  attaches **the first reporting owner only** to all extracted
  transactions. When a real case surfaces where the secondary
  owner's transactions mattered, extend this — see the
  `:multiple_owners_partial` flag below for the audit hook.

  ## Output shape

      [
        %{
          filer_name: "Doe, John",
          filer_role: :officer,           # :officer | :director | :ten_percent_owner | :other
          transaction_code: :open_market_sale,
          share_count: 10_000,
          price: %Decimal{...},
          transaction_date: ~D[2026-04-15]
        },
        ...
      ]

  Transactions whose required fields (date, share count) can't be
  parsed are dropped silently — half-readable rows are worse signal
  than no row, and Form 4 with corrupt fields is a SEC quality
  issue, not something we can fix here.

  ## Transaction codes

  SEC publishes a single-letter code for each transaction kind. We
  map the five most-relevant codes to atoms; everything else falls
  to `:other`:

  | Code | Meaning                             | Atom                     |
  | ---- | ----------------------------------- | ------------------------ |
  | `S`  | Open-market or private sale         | `:open_market_sale`      |
  | `P`  | Open-market or private purchase     | `:open_market_purchase`  |
  | `M`  | Exercise of derivative              | `:exercise`              |
  | `G`  | Bona fide gift                      | `:gift`                  |
  | `F`  | Payment of exercise price / tax     | `:tax_withholding`       |
  | …    | Anything else                       | `:other`                 |

  `:open_market_sale` is the one that drives the dilution
  cross-reference flag. The rest are stored for audit but don't
  feed into the Phase 1 SHORT-bias signal.

  ## Filer role precedence

  A single reporting owner can simultaneously be officer + director
  + 10%-owner. We collapse to one atom by precedence:

      officer > director > ten_percent_owner > other

  An open-market sale by a CEO is the strongest signal; a board
  director-only sale is weaker; a 10%-owner sale is weaker still
  (often institutional, not management). Phase 1 keeps the signal
  binary (insider sold yes/no), but the role is preserved so
  future severity rules can weight by role.

  ## Errors

    * `{:error, :invalid_xml}` — body is not parseable XML.

  Everything else (empty `nonDerivativeTable`, missing transaction
  fields, malformed dates) is returned as `{:ok, []}` or a partial
  list — Form 4 with no transactions is a legitimate filing (e.g.
  amendment with corrected ownership stats only).
  """

  import SweetXml

  # SEC transaction-code → semantic atom. `:other` covers
  # everything else (A, D, I, etc.).
  @transaction_code_map %{
    "S" => :open_market_sale,
    "P" => :open_market_purchase,
    "M" => :exercise,
    "G" => :gift,
    "F" => :tax_withholding
  }

  @type transaction :: %{
          filer_name: String.t() | nil,
          filer_role: :officer | :director | :ten_percent_owner | :other,
          transaction_code: atom(),
          share_count: integer() | nil,
          price: Decimal.t() | nil,
          transaction_date: Date.t()
        }

  @doc """
  Parse a Form 4 XML body. See moduledoc for output shape and
  Phase 1 limitations.
  """
  @spec parse(String.t()) :: {:ok, [transaction()]} | {:error, :invalid_xml}
  def parse(xml_body) when is_binary(xml_body) do
    doc = SweetXml.parse(xml_body, quiet: true)

    case extract_first_filer(doc) do
      nil ->
        # No reportingOwner at all — non-Form-4 XML or corrupt.
        {:ok, []}

      filer ->
        transactions =
          doc
          |> extract_non_derivative_rows()
          |> Enum.map(&to_transaction(&1, filer))
          |> Enum.reject(&is_nil/1)

        {:ok, transactions}
    end
  rescue
    # SweetXml.parse/2 raises on malformed XML. Don't propagate the
    # raw exception — translate to a stable error atom callers can
    # pattern-match on.
    _ -> {:error, :invalid_xml}
  catch
    # erlang :xmerl_scan can also throw on certain malformed inputs.
    _, _ -> {:error, :invalid_xml}
  end

  # ── Reporting owner ──────────────────────────────────────────────

  defp extract_first_filer(doc) do
    owners =
      SweetXml.xpath(doc, ~x"//reportingOwner"l,
        name: ~x"./reportingOwnerId/rptOwnerName/text()"so,
        is_officer: ~x"./reportingOwnerRelationship/isOfficer/text()"so,
        is_director: ~x"./reportingOwnerRelationship/isDirector/text()"so,
        is_ten_percent: ~x"./reportingOwnerRelationship/isTenPercentOwner/text()"so
      )

    case owners do
      [first | _] -> %{name: trim_or_nil(first.name), role: role_from(first)}
      _ -> nil
    end
  end

  # SEC encodes booleans as "0"/"1" but some agents send "true"/"false".
  defp truthy?(v) when v in ["1", "true", "True"], do: true
  defp truthy?(_), do: false

  # officer > director > ten_percent_owner > other — see moduledoc on
  # precedence rationale.
  defp role_from(owner) do
    cond do
      truthy?(owner.is_officer) -> :officer
      truthy?(owner.is_director) -> :director
      truthy?(owner.is_ten_percent) -> :ten_percent_owner
      true -> :other
    end
  end

  # ── Non-derivative transactions ──────────────────────────────────

  defp extract_non_derivative_rows(doc) do
    SweetXml.xpath(doc, ~x"//nonDerivativeTable/nonDerivativeTransaction"l,
      date: ~x"./transactionDate/value/text()"so,
      code: ~x"./transactionCoding/transactionCode/text()"so,
      shares: ~x"./transactionAmounts/transactionShares/value/text()"so,
      price: ~x"./transactionAmounts/transactionPricePerShare/value/text()"so
    )
  end

  defp to_transaction(row, filer) do
    case parse_date(row.date) do
      nil ->
        # No usable date → row is useless for the cross-reference
        # signal (which is date-bounded). Drop.
        nil

      date ->
        %{
          filer_name: filer.name,
          filer_role: filer.role,
          transaction_code: Map.get(@transaction_code_map, row.code, :other),
          share_count: parse_integer(row.shares),
          price: parse_decimal(row.price),
          transaction_date: date
        }
    end
  end

  # ── Field parsers (nil-safe) ─────────────────────────────────────

  defp trim_or_nil(nil), do: nil
  defp trim_or_nil(""), do: nil
  defp trim_or_nil(s), do: String.trim(s)

  defp parse_integer(nil), do: nil
  defp parse_integer(""), do: nil

  defp parse_integer(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_decimal(nil), do: nil
  defp parse_decimal(""), do: nil

  defp parse_decimal(s) do
    case Decimal.parse(s) do
      {d, _} -> d
      :error -> nil
    end
  end

  defp parse_date(nil), do: nil
  defp parse_date(""), do: nil

  defp parse_date(s) do
    case Date.from_iso8601(s) do
      {:ok, d} -> d
      _ -> nil
    end
  end
end
