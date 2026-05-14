defmodule LongOrShort.Tickers.Workers.IwmUniverseSyncTest do
  use LongOrShort.DataCase, async: true

  require Ash.Query

  alias LongOrShort.Tickers
  alias LongOrShort.Tickers.SmallCapUniverseMembership
  alias LongOrShort.Tickers.Workers.IwmUniverseSync

  import LongOrShort.TickersFixtures

  describe "run/2 — happy path" do
    test "upserts a Ticker and creates an active membership for each holding" do
      holdings = [
        %{symbol: "NEWA", name: "New Co A", sector: "Industrials", exchange: :nasdaq},
        %{symbol: "NEWB", name: "New Co B", sector: "Financials", exchange: :nyse}
      ]

      IwmUniverseSync.run(holdings, DateTime.utc_now())

      {:ok, active} =
        Tickers.list_active_small_cap_memberships(authorize?: false)

      symbols = Enum.map(active, & &1.ticker.symbol) |> Enum.sort()
      assert symbols == ["NEWA", "NEWB"]
    end

    test "enriches an existing Ticker with sector and exchange" do
      existing =
        build_ticker(%{
          symbol: "EXIST",
          sector: nil,
          exchange: :other
        })

      IwmUniverseSync.run(
        [
          %{
            symbol: "EXIST",
            name: "Existing Co",
            sector: "Health Care",
            exchange: :nasdaq
          }
        ],
        DateTime.utc_now()
      )

      {:ok, updated} = Tickers.get_ticker_by_symbol("EXIST", authorize?: false)
      assert updated.id == existing.id
      assert updated.sector == "Health Care"
      assert updated.exchange == :nasdaq
    end
  end

  describe "run/2 — stale handling" do
    test "deactivates :iwm memberships whose last_seen_at predates this batch" do
      stale_ticker = build_ticker(%{symbol: "STALE"})

      {:ok, stale} =
        Tickers.upsert_small_cap_membership(
          %{ticker_id: stale_ticker.id, source: :iwm},
          authorize?: false
        )

      assert stale.is_active == true

      # batch_started_at captured after the pre-seed; Ash + DB roundtrip
      # guarantees strict ordering vs the upsert's last_seen_at.
      batch_started_at = DateTime.utc_now()

      IwmUniverseSync.run(
        [%{symbol: "FRESH", name: "Fresh Co", sector: "Tech", exchange: :nasdaq}],
        batch_started_at
      )

      refreshed =
        SmallCapUniverseMembership
        |> Ash.Query.filter(id == ^stale.id)
        |> Ash.read_one!(authorize?: false)

      assert refreshed.is_active == false
    end

    test "leaves memberships from other sources alone" do
      ticker = build_ticker(%{symbol: "MANUAL1"})

      {:ok, manual} =
        Tickers.upsert_small_cap_membership(
          %{ticker_id: ticker.id, source: :manual},
          authorize?: false
        )

      IwmUniverseSync.run([], DateTime.utc_now())

      refreshed =
        SmallCapUniverseMembership
        |> Ash.Query.filter(id == ^manual.id)
        |> Ash.read_one!(authorize?: false)

      assert refreshed.is_active == true
    end
  end

  describe "run/2 — telemetry" do
    test "emits :sync_complete with counts and source metadata" do
      attach_telemetry()

      stale_ticker = build_ticker(%{symbol: "OLDONE"})

      {:ok, _} =
        Tickers.upsert_small_cap_membership(
          %{ticker_id: stale_ticker.id, source: :iwm},
          authorize?: false
        )

      holdings = [
        %{symbol: "FRESH1", name: "Fresh 1", sector: "Tech", exchange: :nasdaq},
        %{symbol: "FRESH2", name: "Fresh 2", sector: "Health Care", exchange: :nyse}
      ]

      IwmUniverseSync.run(holdings, DateTime.utc_now())

      assert_receive {:telemetry, :sync_complete, measurements, metadata}
      assert measurements.ok == 2
      assert measurements.errors == 0
      assert measurements.equity_rows == 2
      assert measurements.deactivated == 1
      assert measurements.active_universe_size == 2
      assert metadata == %{source: :iwm}
    end
  end

  defp attach_telemetry do
    handler_id = "iwm-sync-test-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:long_or_short, :small_cap_universe, :sync_complete],
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, :sync_complete, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end
end
