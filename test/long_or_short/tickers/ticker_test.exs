defmodule LongOrShort.Tickers.TickerTest do
  @moduledoc """
  Unit tests for `LongOrShort.Tickers.Ticker`.

  Organized by action, with separate blocks for cross-cutting concerns
  (symbol normalization, policies).
  """

  use LongOrShort.DataCase, async: true

  import LongOrShort.{AccountsFixtures, TickersFixtures}

  alias LongOrShort.Tickers
  alias LongOrShort.Tickers.Ticker

  describe "create_ticker/2" do
    test "creates a ticker with valid attributes" do
      {:ok, ticker} =
        Tickers.create_ticker(
          %{
            symbol: "BTBD",
            company_name: "Bit Digital, Inc.",
            exchange: :nasdaq,
            float_shares: 45_000_000,
            is_active: true
          },
          actor: system_actor()
        )

      assert ticker.symbol == "BTBD"
      assert ticker.company_name == "Bit Digital, Inc."
      assert ticker.exchange == :nasdaq
      assert ticker.float_shares == 45_000_000
      assert ticker.is_active == true
      assert ticker.id
      assert %DateTime{} = ticker.inserted_at
    end

    test "defaults is_active to true when not provided" do
      {:ok, ticker} =
        Tickers.create_ticker(
          %{symbol: "AAPL", exchange: :nasdaq},
          actor: system_actor()
        )

      assert ticker.is_active == true
    end

    test "requires symbol" do
      assert {:error, %Ash.Error.Invalid{} = error} =
               Tickers.create_ticker(
                 %{company_name: "No Symbol Co"},
                 actor: system_actor()
               )

      assert error_on_field?(error, :symbol)
    end

    test "rejects unknown exchange value" do
      assert {:error, %Ash.Error.Invalid{} = error} =
               Tickers.create_ticker(
                 %{symbol: "XYZ", exchange: :kospi},
                 actor: system_actor()
               )

      assert error_on_field?(error, :exchange)
    end

    test "enforces unique symbol" do
      build_ticker(%{symbol: "DUPE"})

      assert {:error, %Ash.Error.Invalid{} = error} =
               Tickers.create_ticker(
                 %{symbol: "DUPE", exchange: :nasdaq},
                 actor: system_actor()
               )

      assert error_on_field?(error, :symbol)
    end
  end

  describe "symbol normalization" do
    test "uppercases lowercase input on create" do
      {:ok, ticker} =
        Tickers.create_ticker(
          %{symbol: "btbd", exchange: :nasdaq},
          actor: system_actor()
        )

      assert ticker.symbol == "BTBD"
    end

    test "trims whitespace on create" do
      {:ok, ticker} =
        Tickers.create_ticker(
          %{symbol: "  aapl  ", exchange: :nasdaq},
          actor: system_actor()
        )

      assert ticker.symbol == "AAPL"
    end

    test "leaves already-uppercase symbol untouched" do
      {:ok, ticker} =
        Tickers.create_ticker(
          %{symbol: "TSLA", exchange: :nasdaq},
          actor: system_actor()
        )

      assert ticker.symbol == "TSLA"
    end

    test "treats different casings as the same symbol via unique constraint" do
      build_ticker(%{symbol: "MSFT"})

      assert {:error, %Ash.Error.Invalid{}} =
               Tickers.create_ticker(
                 %{symbol: "msft", exchange: :nasdaq},
                 actor: system_actor()
               )
    end
  end

  describe "update_ticker_price/3" do
    test "updates last_price and sets last_price_updated_at" do
      ticker = build_ticker()
      before = DateTime.utc_now()

      {:ok, updated} =
        Tickers.update_ticker_price(ticker, Decimal.new("1.75"), actor: system_actor())

      assert Decimal.equal?(updated.last_price, Decimal.new("1.75"))
      assert %DateTime{} = updated.last_price_updated_at
      assert DateTime.compare(updated.last_price_updated_at, before) in [:gt, :eq]
    end

    test "does not affect unrelated attributes" do
      ticker =
        build_ticker(%{
          symbol: "NVDA",
          company_name: "NVIDIA",
          float_shares: 2_000_000
        })

      {:ok, updated} =
        Tickers.update_ticker_price(ticker, Decimal.new("500.00"), actor: system_actor())

      assert updated.symbol == "NVDA"
      assert updated.company_name == "NVIDIA"
      assert updated.float_shares == 2_000_000
    end
  end

  describe "upsert_ticker_by_symbol/2" do
    test "creates a new ticker when symbol does not exist" do
      {:ok, ticker} =
        Tickers.upsert_ticker_by_symbol(
          %{symbol: "NEWCO", company_name: "Brand New"},
          actor: system_actor()
        )

      assert ticker.symbol == "NEWCO"
      assert ticker.company_name == "Brand New"
    end

    test "updates an existing ticker when symbol matches" do
      existing = build_ticker(%{symbol: "OLDCO", sector: nil})

      {:ok, same} =
        Tickers.upsert_ticker_by_symbol(
          %{symbol: "OLDCO", sector: "Technology"},
          actor: system_actor()
        )

      assert same.id == existing.id
      assert same.sector == "Technology"
    end

    test "matches existing record regardless of input casing" do
      existing = build_ticker(%{symbol: "BTBD"})

      {:ok, same} =
        Tickers.upsert_ticker_by_symbol(
          %{symbol: "btbd", sector: "Crypto Mining"},
          actor: system_actor()
        )

      assert same.id == existing.id
      assert same.symbol == "BTBD"
      assert same.sector == "Crypto Mining"
    end
  end

  describe "get_ticker_by_symbol/2" do
    test "returns the ticker when found" do
      ticker = build_ticker(%{symbol: "GOOG"})

      {:ok, found} = Tickers.get_ticker_by_symbol("GOOG", actor: system_actor())

      assert found.id == ticker.id
    end

    test "returns error when not found" do
      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
               Tickers.get_ticker_by_symbol("NOPE", actor: system_actor())
    end
  end

  describe "list_active_tickers/1" do
    test "returns only active tickers" do
      active = build_ticker(%{symbol: "ACT1", is_active: true})
      _inactive = build_ticker(%{symbol: "DEAD1", is_active: false})

      {:ok, tickers} = Tickers.list_active_tickers(actor: system_actor())

      ids = Enum.map(tickers, & &1.id)
      assert active.id in ids
      refute Enum.any?(tickers, &(&1.is_active == false))
    end

    test "returns empty list when no active tickers exist" do
      {:ok, tickers} = Tickers.list_active_tickers(actor: system_actor())
      assert tickers == []
    end
  end

  describe "policies" do
    setup do
      # A ticker created via the bypass, so it exists regardless of the
      # actor under test.
      ticker = build_ticker(%{symbol: "POLICY1"})
      {:ok, ticker: ticker}
    end

    # ── system actor ───────────────────────────────────────────────────
    test "system actor can create" do
      assert {:ok, _} =
               Tickers.create_ticker(
                 valid_ticker_attrs(%{symbol: "SYS_CREATE"}),
                 actor: system_actor()
               )
    end

    test "system actor can read", %{ticker: ticker} do
      assert {:ok, _} = Tickers.get_ticker_by_symbol(ticker.symbol, actor: system_actor())
    end

    # ── admin user ─────────────────────────────────────────────────────
    test "admin can create" do
      admin = build_admin_user()

      assert {:ok, _} =
               Tickers.create_ticker(
                 valid_ticker_attrs(%{symbol: "ADMIN_CREATE"}),
                 actor: admin
               )
    end

    test "admin can read", %{ticker: ticker} do
      admin = build_admin_user()
      assert {:ok, _} = Tickers.get_ticker_by_symbol(ticker.symbol, actor: admin)
    end

    # ── trader (non-admin authenticated) ──────────────────────────────
    test "trader can read", %{ticker: ticker} do
      trader = build_trader_user()
      assert {:ok, _} = Tickers.get_ticker_by_symbol(ticker.symbol, actor: trader)
    end

    test "trader cannot create" do
      trader = build_trader_user()

      assert {:error, %Ash.Error.Forbidden{}} =
               Tickers.create_ticker(
                 valid_ticker_attrs(%{symbol: "TRADER_CREATE"}),
                 actor: trader
               )
    end

    test "trader cannot update", %{ticker: ticker} do
      trader = build_trader_user()

      assert {:error, %Ash.Error.Forbidden{}} =
               Tickers.update_ticker(ticker, %{company_name: "Hacked"}, actor: trader)
    end

    # ── unauthenticated ────────────────────────────────────────────────
    test "nil actor cannot read" do
      assert {:ok, []} = Tickers.list_active_tickers(actor: nil)
    end

    test "nil actor cannot create" do
      assert {:error, %Ash.Error.Forbidden{}} =
               Tickers.create_ticker(
                 valid_ticker_attrs(%{symbol: "NIL_CREATE"}),
                 actor: nil
               )
    end
  end

  describe "Ticker.Changes.UpcaseSymbol" do
    alias LongOrShort.Tickers.Changes.UpcaseSymbol

    test "uppercases a lowercase binary" do
      changeset =
        Ticker
        |> Ash.Changeset.new()
        |> Ash.Changeset.change_attribute(:symbol, "btbd")
        |> UpcaseSymbol.change([], %{})

      assert Ash.Changeset.get_attribute(changeset, :symbol) == "BTBD"
    end

    test "trims surrounding whitespace" do
      changeset =
        Ticker
        |> Ash.Changeset.new()
        |> Ash.Changeset.change_attribute(:symbol, "  aapl  ")
        |> UpcaseSymbol.change([], %{})

      assert Ash.Changeset.get_attribute(changeset, :symbol) == "AAPL"
    end

    test "leaves the changeset unchanged when symbol is nil" do
      changeset =
        Ticker
        |> Ash.Changeset.new()
        |> UpcaseSymbol.change([], %{})

      assert Ash.Changeset.get_attribute(changeset, :symbol) == nil
    end
  end
end
