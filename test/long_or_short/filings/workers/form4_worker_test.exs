defmodule LongOrShort.Filings.Workers.Form4WorkerTest do
  @moduledoc """
  Integration tests for `LongOrShort.Filings.Workers.Form4Worker` —
  LON-118.

  Hits the real DB (DataCase) and stubs SEC HTTP via `Req.Test`.
  Calls `perform/1` directly — no Oban runtime in test env.
  """

  use LongOrShort.DataCase, async: false

  import LongOrShort.FilingsFixtures
  import LongOrShort.TickersFixtures

  alias LongOrShort.Filings
  alias LongOrShort.Filings.Workers.Form4Worker

  @stub_name __MODULE__

  @form4_xml """
  <?xml version="1.0"?>
  <ownershipDocument>
    <documentType>4</documentType>
    <reportingOwner>
      <reportingOwnerId>
        <rptOwnerName>Doe, John</rptOwnerName>
      </reportingOwnerId>
      <reportingOwnerRelationship>
        <isOfficer>1</isOfficer>
        <isDirector>0</isDirector>
        <isTenPercentOwner>0</isTenPercentOwner>
      </reportingOwnerRelationship>
    </reportingOwner>
    <nonDerivativeTable>
      <nonDerivativeTransaction>
        <transactionDate><value>2026-04-15</value></transactionDate>
        <transactionCoding>
          <transactionCode>S</transactionCode>
        </transactionCoding>
        <transactionAmounts>
          <transactionShares><value>10000</value></transactionShares>
          <transactionPricePerShare><value>5.25</value></transactionPricePerShare>
        </transactionAmounts>
      </nonDerivativeTransaction>
    </nonDerivativeTable>
  </ownershipDocument>
  """

  @empty_form4_xml """
  <?xml version="1.0"?>
  <ownershipDocument>
    <documentType>4</documentType>
    <reportingOwner>
      <reportingOwnerId>
        <rptOwnerName>Doe, John</rptOwnerName>
      </reportingOwnerId>
      <reportingOwnerRelationship>
        <isOfficer>1</isOfficer>
        <isDirector>0</isDirector>
        <isTenPercentOwner>0</isTenPercentOwner>
      </reportingOwnerRelationship>
    </reportingOwner>
    <nonDerivativeTable />
  </ownershipDocument>
  """

  setup do
    prev = Application.get_env(:long_or_short, :form4_worker_req_plug)
    Application.put_env(:long_or_short, :form4_worker_req_plug, {Req.Test, @stub_name})

    on_exit(fn ->
      if prev do
        Application.put_env(:long_or_short, :form4_worker_req_plug, prev)
      else
        Application.delete_env(:long_or_short, :form4_worker_req_plug)
      end
    end)

    :ok
  end

  defp stub(fun), do: Req.Test.stub(@stub_name, fun)

  defp build_form4_filing(ticker, opts \\ %{}) do
    base = %{
      filing_type: :form4,
      url:
        Map.get(
          opts,
          :url,
          "https://www.sec.gov/Archives/edgar/data/100/0000100000-26-000001/0000100000-26-000001-index.htm"
        )
    }

    build_filing_for_ticker(ticker, Map.merge(base, Map.drop(opts, [:url])))
  end

  describe "perform/1 — no pending work" do
    test "returns :ok when no Form 4 filings exist" do
      assert :ok = Form4Worker.perform(%Oban.Job{})
    end
  end

  describe "perform/1 — happy path" do
    test "fetches XML, parses, and inserts InsiderTransaction rows" do
      ticker = build_ticker()
      filing = build_form4_filing(ticker)

      stub(fn conn ->
        cond do
          String.ends_with?(conn.request_path, "/index.json") ->
            Req.Test.json(conn, %{
              "directory" => %{"item" => [%{"name" => "wf-form4_doc.xml"}]}
            })

          String.ends_with?(conn.request_path, ".xml") ->
            Plug.Conn.send_resp(conn, 200, @form4_xml)
        end
      end)

      assert :ok = Form4Worker.perform(%Oban.Job{})

      {:ok, [tx]} =
        Filings.list_insider_transactions_by_filing(filing.id, authorize?: false)

      assert tx.filer_name == "Doe, John"
      assert tx.filer_role == :officer
      assert tx.transaction_code == :open_market_sale
      assert tx.share_count == 10_000
      assert Decimal.equal?(tx.price, Decimal.new("5.25"))
      assert tx.transaction_date == ~D[2026-04-15]
      assert tx.ticker_id == ticker.id
    end
  end

  describe "perform/1 — idempotency" do
    test "filing with existing InsiderTransaction is skipped (no HTTP fetch)" do
      ticker = build_ticker()
      filing = build_form4_filing(ticker)
      _existing = build_insider_transaction(filing)

      # No stub installed. If the worker tries to fetch, Req.Test
      # raises "no plug stubbed" — proving the aggregate-based
      # `insider_transaction_count == 0` query short-circuits.
      assert :ok = Form4Worker.perform(%Oban.Job{})

      {:ok, transactions} =
        Filings.list_insider_transactions_by_filing(filing.id, authorize?: false)

      # Existing row untouched, no new rows added.
      assert length(transactions) == 1
    end
  end

  describe "perform/1 — empty Form 4 (derivative-only / amendment)" do
    test "Form 4 with no nonDerivativeTransaction rows leaves DB untouched" do
      ticker = build_ticker()
      filing = build_form4_filing(ticker)

      stub(fn conn ->
        cond do
          String.ends_with?(conn.request_path, "/index.json") ->
            Req.Test.json(conn, %{
              "directory" => %{"item" => [%{"name" => "form4.xml"}]}
            })

          String.ends_with?(conn.request_path, ".xml") ->
            Plug.Conn.send_resp(conn, 200, @empty_form4_xml)
        end
      end)

      assert :ok = Form4Worker.perform(%Oban.Job{})

      {:ok, transactions} =
        Filings.list_insider_transactions_by_filing(filing.id, authorize?: false)

      assert transactions == []
    end
  end

  describe "perform/1 — error handling" do
    test "HTTP 500 on index.json doesn't crash the cycle; filing left for retry" do
      ticker = build_ticker()
      filing = build_form4_filing(ticker)

      stub(fn conn ->
        Plug.Conn.send_resp(conn, 500, "SEC unavailable")
      end)

      assert :ok = Form4Worker.perform(%Oban.Job{})

      # Filing still has no transactions — eligible for next cycle.
      {:ok, transactions} =
        Filings.list_insider_transactions_by_filing(filing.id, authorize?: false)

      assert transactions == []
    end

    test "malformed XML logs an error and leaves the filing for retry" do
      ticker = build_ticker()
      filing = build_form4_filing(ticker)

      stub(fn conn ->
        cond do
          String.ends_with?(conn.request_path, "/index.json") ->
            Req.Test.json(conn, %{
              "directory" => %{"item" => [%{"name" => "broken.xml"}]}
            })

          String.ends_with?(conn.request_path, ".xml") ->
            Plug.Conn.send_resp(conn, 200, "<not<valid xml")
        end
      end)

      assert :ok = Form4Worker.perform(%Oban.Job{})

      {:ok, transactions} =
        Filings.list_insider_transactions_by_filing(filing.id, authorize?: false)

      assert transactions == []
    end

    test "index.json with no XML file present is skipped, filing remains pending" do
      ticker = build_ticker()
      filing = build_form4_filing(ticker)

      stub(fn conn ->
        cond do
          String.ends_with?(conn.request_path, "/index.json") ->
            Req.Test.json(conn, %{
              "directory" => %{
                "item" => [
                  %{"name" => "form4.xsd"},
                  %{"name" => "exhibit.htm"}
                ]
              }
            })
        end
      end)

      assert :ok = Form4Worker.perform(%Oban.Job{})

      {:ok, transactions} =
        Filings.list_insider_transactions_by_filing(filing.id, authorize?: false)

      assert transactions == []
    end
  end

  describe "perform/1 — non-Form-4 filings filtered out" do
    test "S-1 filing with no transactions is not picked up" do
      ticker = build_ticker()
      _s1 = build_filing_for_ticker(ticker, %{filing_type: :s1})

      # No stub — if worker tries to fetch, Req.Test raises.
      assert :ok = Form4Worker.perform(%Oban.Job{})
    end
  end
end
