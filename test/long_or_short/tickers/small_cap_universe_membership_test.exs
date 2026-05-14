defmodule LongOrShort.Tickers.SmallCapUniverseMembershipTest do
  use LongOrShort.DataCase, async: true

  require Ash.Query

  alias LongOrShort.Tickers
  alias LongOrShort.Tickers.SmallCapUniverseMembership

  import LongOrShort.TickersFixtures

  describe ":upsert_observed" do
    test "creates a new active membership" do
      ticker = build_ticker()

      assert {:ok, m} =
               Tickers.upsert_small_cap_membership(
                 %{ticker_id: ticker.id, source: :iwm},
                 authorize?: false
               )

      assert m.ticker_id == ticker.id
      assert m.source == :iwm
      assert m.is_active == true
      assert m.first_seen_at != nil
      assert m.last_seen_at != nil
    end

    test "second upsert collapses onto the same row via (ticker_id, source) identity" do
      ticker = build_ticker()

      {:ok, first} =
        Tickers.upsert_small_cap_membership(
          %{ticker_id: ticker.id, source: :iwm},
          authorize?: false
        )

      {:ok, second} =
        Tickers.upsert_small_cap_membership(
          %{ticker_id: ticker.id, source: :iwm},
          authorize?: false
        )

      assert second.id == first.id
      assert second.first_seen_at == first.first_seen_at
    end

    test "reactivates a previously deactivated membership" do
      ticker = build_ticker()

      {:ok, m} =
        Tickers.upsert_small_cap_membership(
          %{ticker_id: ticker.id, source: :iwm},
          authorize?: false
        )

      SmallCapUniverseMembership
      |> Ash.Query.filter(id == ^m.id)
      |> Ash.bulk_update!(:deactivate, %{}, authorize?: false)

      {:ok, refreshed} =
        Tickers.upsert_small_cap_membership(
          %{ticker_id: ticker.id, source: :iwm},
          authorize?: false
        )

      assert refreshed.id == m.id
      assert refreshed.is_active == true
    end
  end

  describe ":list_active" do
    test "returns only active memberships with their ticker loaded" do
      t1 = build_ticker(%{symbol: "AAAA"})
      t2 = build_ticker(%{symbol: "BBBB"})
      t3 = build_ticker(%{symbol: "CCCC"})

      {:ok, _} =
        Tickers.upsert_small_cap_membership(
          %{ticker_id: t1.id, source: :iwm},
          authorize?: false
        )

      {:ok, m2} =
        Tickers.upsert_small_cap_membership(
          %{ticker_id: t2.id, source: :iwm},
          authorize?: false
        )

      {:ok, _} =
        Tickers.upsert_small_cap_membership(
          %{ticker_id: t3.id, source: :iwm},
          authorize?: false
        )

      SmallCapUniverseMembership
      |> Ash.Query.filter(id == ^m2.id)
      |> Ash.bulk_update!(:deactivate, %{}, authorize?: false)

      {:ok, active} = Tickers.list_active_small_cap_memberships(authorize?: false)
      symbols = Enum.map(active, & &1.ticker.symbol) |> Enum.sort()

      assert symbols == ["AAAA", "CCCC"]
    end
  end
end
