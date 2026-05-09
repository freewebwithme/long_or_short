defmodule LongOrShort.Filings.FilingRawTest do
  @moduledoc """
  Unit tests for `LongOrShort.Filings.FilingRaw`.

  The cascade-delete test is the load-bearing one — without it, a future
  edit that drops the FK action would silently leak orphan rows in
  production.
  """

  use LongOrShort.DataCase, async: true

  import LongOrShort.{FilingsFixtures, AccountsFixtures}

  alias LongOrShort.Filings

  describe "create_filing_raw/2" do
    test "creates a raw row attached to a filing" do
      filing = build_filing()

      {:ok, raw} =
        Filings.create_filing_raw(
          %{
            filing_id: filing.id,
            raw_text: "Sample 8-K body.",
            content_hash: "abc123"
          },
          authorize?: false
        )

      assert raw.filing_id == filing.id
      assert raw.raw_text == "Sample 8-K body."
      assert raw.content_hash == "abc123"
      assert %DateTime{} = raw.fetched_at
    end

    test "requires filing_id, raw_text, content_hash" do
      filing = build_filing()

      base = %{
        filing_id: filing.id,
        raw_text: "body",
        content_hash: "h"
      }

      for {field, _} <- base do
        attrs = Map.delete(base, field)

        assert {:error, %Ash.Error.Invalid{} = error} =
                 Filings.create_filing_raw(attrs, authorize?: false),
               "expected error when missing #{field}"

        assert error_on_field?(error, field)
      end
    end
  end

  describe "identity" do
    test "rejects a second FilingRaw for the same filing" do
      filing = build_filing()
      _first = build_filing_raw(filing)

      assert {:error, %Ash.Error.Invalid{} = error} =
               Filings.create_filing_raw(
                 valid_filing_raw_attrs() |> Map.put(:filing_id, filing.id),
                 authorize?: false
               )

      assert error_on_field?(error, :filing_id)
    end
  end

  describe "cascade delete" do
    test "destroying the parent Filing also destroys its FilingRaw" do
      filing = build_filing()
      raw = build_filing_raw(filing)

      assert :ok = Filings.destroy_filing(filing, authorize?: false)

      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
               Filings.get_filing_raw(raw.filing_id, authorize?: false)
    end
  end

  describe "get_filing_raw/2" do
    test "fetches by filing_id" do
      filing = build_filing()
      raw = build_filing_raw(filing)

      assert {:ok, fetched} =
               Filings.get_filing_raw(filing.id, authorize?: false)

      assert fetched.id == raw.id
      assert fetched.raw_text == raw.raw_text
    end

    test "returns NotFound for an unknown filing_id" do
      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
               Filings.get_filing_raw(Ash.UUID.generate(), authorize?: false)
    end
  end

  describe "Filing.filing_raw relationship" do
    test "loads the FilingRaw via the parent Filing" do
      filing = build_filing()
      _raw = build_filing_raw(filing, %{raw_text: "loaded body"})

      loaded = Ash.load!(filing, :filing_raw, authorize?: false)
      assert loaded.filing_raw.raw_text == "loaded body"
    end

    test "loads as nil when no FilingRaw exists" do
      filing = build_filing()

      loaded = Ash.load!(filing, :filing_raw, authorize?: false)
      assert is_nil(loaded.filing_raw)
    end
  end

  describe "policies" do
    test "system actor can create" do
      filing = build_filing()

      assert {:ok, _} =
               Filings.create_filing_raw(
                 valid_filing_raw_attrs() |> Map.put(:filing_id, filing.id),
                 actor: LongOrShort.Accounts.SystemActor.new()
               )
    end

    test "trader can read" do
      filing = build_filing()
      raw = build_filing_raw(filing)
      trader = build_trader_user()

      assert {:ok, fetched} = Filings.get_filing_raw(raw.filing_id, actor: trader)
      assert fetched.id == raw.id
    end

    test "trader cannot create" do
      filing = build_filing()
      trader = build_trader_user()

      assert {:error, %Ash.Error.Forbidden{}} =
               Filings.create_filing_raw(
                 valid_filing_raw_attrs() |> Map.put(:filing_id, filing.id),
                 actor: trader
               )
    end

    test "nil actor cannot create" do
      filing = build_filing()

      assert {:error, %Ash.Error.Forbidden{}} =
               Filings.create_filing_raw(
                 valid_filing_raw_attrs() |> Map.put(:filing_id, filing.id),
                 actor: nil
               )
    end
  end
end
