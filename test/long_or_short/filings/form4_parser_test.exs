defmodule LongOrShort.Filings.Form4ParserTest do
  @moduledoc """
  Unit tests for `LongOrShort.Filings.Form4Parser` — LON-118.

  Synthetic Form 4 ownership XML fixtures exercise transaction
  code mapping, filer role precedence, the
  multiple-reporting-owners edge case, and graceful handling of
  malformed input.
  """

  use ExUnit.Case, async: true

  alias LongOrShort.Filings.Form4Parser

  # Minimal Form 4 XML with overrideable fragments. Each test
  # composes the bits it needs.
  defp xml(opts \\ []) do
    owners =
      Keyword.get(
        opts,
        :owners,
        [
          %{
            name: "Doe, John",
            is_officer: "1",
            is_director: "0",
            is_ten_percent: "0"
          }
        ]
      )

    transactions =
      Keyword.get(
        opts,
        :transactions,
        [
          %{date: "2026-04-15", code: "S", shares: "10000", price: "5.25"}
        ]
      )

    """
    <?xml version="1.0"?>
    <ownershipDocument>
      <schemaVersion>X0407</schemaVersion>
      <documentType>4</documentType>
      <periodOfReport>2026-04-15</periodOfReport>
      <issuer>
        <issuerName>Example Corp</issuerName>
        <issuerTradingSymbol>EXMP</issuerTradingSymbol>
      </issuer>
      #{Enum.map_join(owners, "\n", &render_owner/1)}
      <nonDerivativeTable>
        #{Enum.map_join(transactions, "\n", &render_transaction/1)}
      </nonDerivativeTable>
    </ownershipDocument>
    """
  end

  defp render_owner(owner) do
    """
    <reportingOwner>
      <reportingOwnerId>
        <rptOwnerName>#{owner.name}</rptOwnerName>
      </reportingOwnerId>
      <reportingOwnerRelationship>
        <isDirector>#{owner.is_director}</isDirector>
        <isOfficer>#{owner.is_officer}</isOfficer>
        <isTenPercentOwner>#{owner.is_ten_percent}</isTenPercentOwner>
      </reportingOwnerRelationship>
    </reportingOwner>
    """
  end

  defp render_transaction(t) do
    price_block =
      case t[:price] do
        nil ->
          ""

        price ->
          """
          <transactionPricePerShare>
            <value>#{price}</value>
          </transactionPricePerShare>
          """
      end

    shares_block =
      case t[:shares] do
        nil ->
          ""

        shares ->
          """
          <transactionShares>
            <value>#{shares}</value>
          </transactionShares>
          """
      end

    """
    <nonDerivativeTransaction>
      <transactionDate>
        <value>#{t.date}</value>
      </transactionDate>
      <transactionCoding>
        <transactionCode>#{t.code}</transactionCode>
      </transactionCoding>
      <transactionAmounts>
        #{shares_block}
        #{price_block}
      </transactionAmounts>
    </nonDerivativeTransaction>
    """
  end

  describe "parse/1 — happy path" do
    test "extracts a single open-market sale" do
      assert {:ok, [tx]} = Form4Parser.parse(xml())

      assert tx.filer_name == "Doe, John"
      assert tx.filer_role == :officer
      assert tx.transaction_code == :open_market_sale
      assert tx.share_count == 10_000
      assert Decimal.equal?(tx.price, Decimal.new("5.25"))
      assert tx.transaction_date == ~D[2026-04-15]
    end

    test "extracts multiple transactions on the same day" do
      txs = [
        %{date: "2026-04-15", code: "S", shares: "5000", price: "5.20"},
        %{date: "2026-04-15", code: "S", shares: "5000", price: "5.30"}
      ]

      assert {:ok, [t1, t2]} = Form4Parser.parse(xml(transactions: txs))

      assert t1.share_count == 5_000
      assert t2.share_count == 5_000
      assert Decimal.equal?(t1.price, Decimal.new("5.20"))
      assert Decimal.equal?(t2.price, Decimal.new("5.30"))
    end
  end

  describe "parse/1 — transaction code mapping" do
    for {code, expected} <- [
          {"S", :open_market_sale},
          {"P", :open_market_purchase},
          {"M", :exercise},
          {"G", :gift},
          {"F", :tax_withholding},
          {"X", :other},
          {"A", :other},
          {"Z", :other}
        ] do
      test "code #{code} maps to #{expected}" do
        body =
          xml(
            transactions: [
              %{date: "2026-04-15", code: unquote(code), shares: "100", price: "1.00"}
            ]
          )

        assert {:ok, [tx]} = Form4Parser.parse(body)
        assert tx.transaction_code == unquote(expected)
      end
    end
  end

  describe "parse/1 — filer role precedence" do
    test "officer wins when also a director" do
      body =
        xml(
          owners: [
            %{name: "CEO + Board", is_officer: "1", is_director: "1", is_ten_percent: "0"}
          ]
        )

      assert {:ok, [tx]} = Form4Parser.parse(body)
      assert tx.filer_role == :officer
    end

    test "director when not officer" do
      body =
        xml(
          owners: [
            %{name: "Board Only", is_officer: "0", is_director: "1", is_ten_percent: "0"}
          ]
        )

      assert {:ok, [tx]} = Form4Parser.parse(body)
      assert tx.filer_role == :director
    end

    test "ten_percent_owner when not officer or director" do
      body =
        xml(
          owners: [
            %{name: "Big Holder", is_officer: "0", is_director: "0", is_ten_percent: "1"}
          ]
        )

      assert {:ok, [tx]} = Form4Parser.parse(body)
      assert tx.filer_role == :ten_percent_owner
    end

    test ":other when no role flag is set" do
      body =
        xml(
          owners: [
            %{name: "Mystery", is_officer: "0", is_director: "0", is_ten_percent: "0"}
          ]
        )

      assert {:ok, [tx]} = Form4Parser.parse(body)
      assert tx.filer_role == :other
    end

    test "accepts 'true'/'false' as well as '1'/'0'" do
      body =
        xml(
          owners: [
            %{name: "True Director", is_officer: "false", is_director: "true", is_ten_percent: "0"}
          ]
        )

      assert {:ok, [tx]} = Form4Parser.parse(body)
      assert tx.filer_role == :director
    end
  end

  describe "parse/1 — multiple reporting owners (Phase 1)" do
    test "uses only the first reporting owner, ignores secondary owners" do
      # Phase 1 simplification — rare edge case (<1% of filings).
      # If a real case ever surfaces where the secondary owner mattered,
      # the test must be updated alongside the parser logic.
      body =
        xml(
          owners: [
            %{name: "Primary, CEO", is_officer: "1", is_director: "0", is_ten_percent: "0"},
            %{name: "Secondary, Director", is_officer: "0", is_director: "1", is_ten_percent: "0"}
          ]
        )

      assert {:ok, [tx]} = Form4Parser.parse(body)
      assert tx.filer_name == "Primary, CEO"
      assert tx.filer_role == :officer
    end
  end

  describe "parse/1 — graceful field handling" do
    test "missing price returns nil price (gift case)" do
      body =
        xml(
          transactions: [
            %{date: "2026-04-15", code: "G", shares: "1000"}
          ]
        )

      assert {:ok, [tx]} = Form4Parser.parse(body)
      assert tx.transaction_code == :gift
      assert tx.price == nil
    end

    test "missing share_count returns nil share_count but keeps the row" do
      body =
        xml(
          transactions: [
            %{date: "2026-04-15", code: "S", price: "5.00"}
          ]
        )

      assert {:ok, [tx]} = Form4Parser.parse(body)
      assert tx.share_count == nil
      assert tx.transaction_code == :open_market_sale
    end

    test "row with no transactionDate is dropped (can't be cross-referenced without a date)" do
      txs = [
        %{date: "", code: "S", shares: "1000", price: "5.00"},
        %{date: "2026-04-15", code: "S", shares: "2000", price: "5.00"}
      ]

      assert {:ok, [tx]} = Form4Parser.parse(xml(transactions: txs))
      assert tx.share_count == 2_000
    end
  end

  describe "parse/1 — empty / minimal documents" do
    test "Form 4 with no nonDerivativeTransaction rows returns {:ok, []}" do
      body =
        """
        <?xml version="1.0"?>
        <ownershipDocument>
          <documentType>4</documentType>
          #{render_owner(%{name: "X", is_officer: "1", is_director: "0", is_ten_percent: "0"})}
          <nonDerivativeTable />
        </ownershipDocument>
        """

      assert {:ok, []} = Form4Parser.parse(body)
    end

    test "document with no reportingOwner returns {:ok, []}" do
      body =
        """
        <?xml version="1.0"?>
        <ownershipDocument>
          <documentType>4</documentType>
        </ownershipDocument>
        """

      assert {:ok, []} = Form4Parser.parse(body)
    end
  end

  describe "parse/1 — error cases" do
    test "malformed XML returns :invalid_xml" do
      assert {:error, :invalid_xml} = Form4Parser.parse("<not<valid xml")
    end

    test "empty string returns :invalid_xml" do
      assert {:error, :invalid_xml} = Form4Parser.parse("")
    end
  end
end
