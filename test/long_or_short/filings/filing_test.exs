defmodule LongOrShort.Filings.FilingTest do
  @moduledoc """
  Unit tests for `LongOrShort.Filings.Filing`.

  Organized by action, with separate blocks for the `:ingest` upsert
  behavior, identity rules, and policies.
  """

  use LongOrShort.DataCase, async: true

  import LongOrShort.{FilingsFixtures, TickersFixtures, AccountsFixtures}

  alias LongOrShort.Filings

  describe "create_filing/2" do
    test "creates a filing when given an existing ticker_id" do
      ticker = build_ticker(%{symbol: "AAPL"})

      {:ok, filing} =
        Filings.create_filing(
          %{
            source: :sec_edgar,
            filing_type: :_8k,
            filing_subtype: "8-K Item 3.02",
            external_id: "0001234567-26-000001",
            filer_cik: "0000320193",
            filed_at: DateTime.utc_now(),
            url: "https://www.sec.gov/Archives/edgar/data/320193/index.htm",
            ticker_id: ticker.id
          },
          authorize?: false
        )

      assert filing.ticker_id == ticker.id
      assert filing.source == :sec_edgar
      assert filing.filing_type == :_8k
      assert filing.filing_subtype == "8-K Item 3.02"
      assert filing.external_id == "0001234567-26-000001"
      assert filing.filer_cik == "0000320193"
      assert %DateTime{} = filing.filed_at
      assert %DateTime{} = filing.fetched_at
    end

    test "filing_subtype and url are optional" do
      ticker = build_ticker()

      assert {:ok, filing} =
               Filings.create_filing(
                 valid_filing_attrs()
                 |> Map.drop([:symbol, :filing_subtype, :url])
                 |> Map.put(:ticker_id, ticker.id),
                 authorize?: false
               )

      assert is_nil(filing.filing_subtype)
      assert is_nil(filing.url)
    end

    test "requires source, filing_type, external_id, filer_cik, filed_at, ticker_id" do
      ticker = build_ticker()

      base = %{
        source: :sec_edgar,
        filing_type: :_8k,
        external_id: "ext-base",
        filer_cik: "0000000001",
        filed_at: DateTime.utc_now(),
        ticker_id: ticker.id
      }

      for {field, _} <- base do
        attrs = Map.delete(base, field)

        assert {:error, %Ash.Error.Invalid{} = error} =
                 Filings.create_filing(attrs, authorize?: false),
               "expected error when missing #{field}"

        assert error_on_field?(error, field)
      end
    end

    test "rejects unknown source value" do
      ticker = build_ticker()

      assert {:error, %Ash.Error.Invalid{} = error} =
               Filings.create_filing(
                 valid_filing_attrs(%{source: :benzinga})
                 |> Map.drop([:symbol])
                 |> Map.put(:ticker_id, ticker.id),
                 authorize?: false
               )

      assert error_on_field?(error, :source)
    end

    test "rejects unknown filing_type value" do
      ticker = build_ticker()

      assert {:error, %Ash.Error.Invalid{} = error} =
               Filings.create_filing(
                 valid_filing_attrs(%{filing_type: :_10k})
                 |> Map.drop([:symbol])
                 |> Map.put(:ticker_id, ticker.id),
                 authorize?: false
               )

      assert error_on_field?(error, :filing_type)
    end
  end

  describe "ingest_filing/2" do
    test "creates a Ticker when symbol is unknown" do
      attrs = valid_filing_attrs(%{symbol: "BRAND_NEW"})

      assert {:ok, filing} = Filings.ingest_filing(attrs, authorize?: false)

      ticker = Ash.load!(filing, :ticker, authorize?: false).ticker
      assert ticker.symbol == "BRAND_NEW"
    end

    test "reuses existing Ticker when symbol is known" do
      existing = build_ticker(%{symbol: "EXIST"})
      attrs = valid_filing_attrs(%{symbol: "EXIST"})

      assert {:ok, filing} = Filings.ingest_filing(attrs, authorize?: false)
      assert filing.ticker_id == existing.id
    end

    test "upsert: re-ingest with same (source, external_id, ticker) updates content fields" do
      attrs = valid_filing_attrs(%{symbol: "UPSRT", filing_subtype: nil, url: nil})

      {:ok, original} = Filings.ingest_filing(attrs, authorize?: false)

      updated_attrs =
        Map.merge(attrs, %{
          filing_subtype: "8-K Item 3.02",
          filer_cik: "9999999999",
          url: "https://www.sec.gov/updated"
        })

      {:ok, second} = Filings.ingest_filing(updated_attrs, authorize?: false)

      assert second.id == original.id
      assert second.filing_subtype == "8-K Item 3.02"
      assert second.filer_cik == "9999999999"
      assert second.url == "https://www.sec.gov/updated"
    end

    test "upsert preserves filed_at and fetched_at on re-ingest" do
      original_filed_at = ~U[2026-01-15 10:00:00.000000Z]
      attrs = valid_filing_attrs(%{symbol: "PRESV", filed_at: original_filed_at})

      {:ok, original} = Filings.ingest_filing(attrs, authorize?: false)

      # Re-ingest with a different filed_at — must be ignored.
      later_attrs = Map.put(attrs, :filed_at, ~U[2026-06-01 10:00:00.000000Z])

      {:ok, second} = Filings.ingest_filing(later_attrs, authorize?: false)

      assert DateTime.compare(second.filed_at, original.filed_at) == :eq
      assert DateTime.compare(second.fetched_at, original.fetched_at) == :eq
    end

    test "requires symbol" do
      attrs = valid_filing_attrs() |> Map.delete(:symbol)

      assert {:error, %Ash.Error.Invalid{}} =
               Filings.ingest_filing(attrs, authorize?: false)
    end
  end

  describe "uniqueness" do
    test "same (source, external_id) is allowed for two different tickers" do
      # Multi-ticker filing scenario — rare for SEC but the identity
      # contract mirrors Article and must permit it.
      external_id = "shared-accession-#{System.unique_integer([:positive])}"

      {:ok, _a} =
        Filings.ingest_filing(
          valid_filing_attrs(%{symbol: "TICK_A", external_id: external_id}),
          authorize?: false
        )

      assert {:ok, b} =
               Filings.ingest_filing(
                 valid_filing_attrs(%{symbol: "TICK_B", external_id: external_id}),
                 authorize?: false
               )

      assert b.external_id == external_id
    end

    test "rejects duplicate (source, external_id, ticker_id) on :create" do
      ticker = build_ticker()
      _existing = build_filing_for_ticker(ticker, %{external_id: "dup-1"})

      assert {:error, %Ash.Error.Invalid{}} =
               Filings.create_filing(
                 %{
                   source: :sec_edgar,
                   filing_type: :_8k,
                   external_id: "dup-1",
                   filer_cik: "0000000002",
                   filed_at: DateTime.utc_now(),
                   ticker_id: ticker.id
                 },
                 authorize?: false
               )
    end
  end

  describe "list_filings_by_ticker/2" do
    test "returns only filings for the given ticker, newest first" do
      ticker_a = build_ticker(%{symbol: "LIST_A"})
      ticker_b = build_ticker(%{symbol: "LIST_B"})

      old = build_filing_for_ticker(ticker_a, %{filed_at: ~U[2026-01-01 00:00:00.000000Z]})
      new = build_filing_for_ticker(ticker_a, %{filed_at: ~U[2026-04-01 00:00:00.000000Z]})
      _other = build_filing_for_ticker(ticker_b)

      assert {:ok, results} =
               Filings.list_filings_by_ticker(ticker_a.id, authorize?: false)

      assert Enum.map(results, & &1.id) == [new.id, old.id]
    end
  end

  describe "destroy_filing/2" do
    test "destroys a filing" do
      filing = build_filing()

      assert :ok = Filings.destroy_filing(filing, authorize?: false)

      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
               Filings.get_filing(filing.id, authorize?: false)
    end
  end

  describe "policies" do
    test "system actor can ingest" do
      assert {:ok, _} =
               Filings.ingest_filing(
                 valid_filing_attrs(%{symbol: "SYSING"}),
                 actor: LongOrShort.Accounts.SystemActor.new()
               )
    end

    test "admin can ingest" do
      admin = build_admin_user()

      assert {:ok, _} =
               Filings.ingest_filing(
                 valid_filing_attrs(%{symbol: "ADMING"}),
                 actor: admin
               )
    end

    test "trader can read" do
      filing = build_filing()
      trader = build_trader_user()

      assert {:ok, fetched} = Filings.get_filing(filing.id, actor: trader)
      assert fetched.id == filing.id
    end

    test "trader cannot ingest" do
      trader = build_trader_user()

      assert {:error, %Ash.Error.Forbidden{}} =
               Filings.ingest_filing(
                 valid_filing_attrs(%{symbol: "TRDING"}),
                 actor: trader
               )
    end

    test "nil actor cannot ingest" do
      assert {:error, %Ash.Error.Forbidden{}} =
               Filings.ingest_filing(
                 valid_filing_attrs(%{symbol: "NILING"}),
                 actor: nil
               )
    end
  end
end
