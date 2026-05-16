defmodule LongOrShort.Filings.Workers.FilingBodyFetcherTest do
  @moduledoc """
  Integration tests for `LongOrShort.Filings.Workers.FilingBodyFetcher`.

  Hits real DB (DataCase) and stubs HTTP via `Req.Test`. Calls
  `perform/1` directly — no Oban runtime in test env.
  """

  use LongOrShort.DataCase, async: false

  import LongOrShort.FilingsFixtures

  alias LongOrShort.Filings
  alias LongOrShort.Filings.Workers.FilingBodyFetcher
  alias LongOrShort.Tickers

  defp stub(fun), do: Req.Test.stub(LongOrShort.Filings.BodyFetcher, fun)

  # LON-178: the worker now scopes to `Tickers.small_cap_ticker_ids/0`,
  # so any test that expects a fetch must first seed the universe.
  # Mirrors the `add_to_universe/1` helper in
  # `FilingAnalysisWorkerTest` — same shape on purpose.
  defp add_to_universe(ticker_id) do
    {:ok, _} =
      Tickers.upsert_small_cap_membership(
        %{ticker_id: ticker_id, source: :iwm},
        authorize?: false
      )

    :ok
  end

  describe "perform/1" do
    test "returns :ok with no work when there are no pending Filings" do
      assert :ok = FilingBodyFetcher.perform(%Oban.Job{})
    end

    test "creates FilingRaw for each pending Filing" do
      filing =
        build_filing(%{
          symbol: "WORKAA",
          url:
            "https://www.sec.gov/Archives/edgar/data/100/0000100000-26-000001/0000100000-26-000001-index.htm"
        })

      add_to_universe(filing.ticker_id)

      stub(fn conn ->
        case conn.request_path do
          "/Archives/edgar/data/100/0000100000-26-000001/index.json" ->
            Req.Test.json(conn, %{
              "directory" => %{"item" => [%{"name" => "form8-k.htm"}]}
            })

          "/Archives/edgar/data/100/0000100000-26-000001/form8-k.htm" ->
            Plug.Conn.send_resp(conn, 200, "<p>Worker test content.</p>")
        end
      end)

      assert :ok = FilingBodyFetcher.perform(%Oban.Job{})

      assert {:ok, raw} = Filings.get_filing_raw(filing.id, authorize?: false)
      assert raw.raw_text =~ "Worker test content"
      assert byte_size(raw.content_hash) == 64
    end

    test "skips Filings that already have FilingRaw (idempotency)" do
      filing = build_filing(%{symbol: "WORKBB"})
      _existing = build_filing_raw(filing, %{raw_text: "existing body — do not overwrite"})

      add_to_universe(filing.ticker_id)

      # Intentionally no stub — if the worker tries to fetch, the absence
      # of a stub will surface as an error, proving the skip works.
      assert :ok = FilingBodyFetcher.perform(%Oban.Job{})

      {:ok, raw} = Filings.get_filing_raw(filing.id, authorize?: false)
      assert raw.raw_text == "existing body — do not overwrite"
    end

    test "per-Filing failure does not abort the cycle" do
      good =
        build_filing(%{
          symbol: "GOODFL",
          url: "https://www.sec.gov/Archives/edgar/data/200/0000200000-26-000001/index.htm"
        })

      bad =
        build_filing(%{
          symbol: "BADFL",
          url: "https://www.sec.gov/Archives/edgar/data/300/0000300000-26-000001/index.htm"
        })

      add_to_universe(good.ticker_id)
      add_to_universe(bad.ticker_id)

      stub(fn conn ->
        cond do
          String.contains?(conn.request_path, "/200/0000200000-26-000001/index.json") ->
            Req.Test.json(conn, %{
              "directory" => %{"item" => [%{"name" => "form.htm"}]}
            })

          String.contains?(conn.request_path, "/200/0000200000-26-000001/form.htm") ->
            Plug.Conn.send_resp(conn, 200, "<p>Good content.</p>")

          # Bad filing: 500 on index.json
          String.contains?(conn.request_path, "/300/0000300000-26-000001/index.json") ->
            Plug.Conn.send_resp(conn, 500, "")
        end
      end)

      assert :ok = FilingBodyFetcher.perform(%Oban.Job{})

      # Good was processed
      assert {:ok, _} = Filings.get_filing_raw(good.id, authorize?: false)

      # Bad still has no FilingRaw — next cron will retry
      assert {:error, _} = Filings.get_filing_raw(bad.id, authorize?: false)
    end

    test "processes oldest Filings first" do
      old =
        build_filing(%{
          symbol: "OLDFLG",
          filed_at: ~U[2026-01-01 00:00:00.000000Z],
          url: "https://www.sec.gov/Archives/edgar/data/400/oldold/index.htm"
        })

      new_filing =
        build_filing(%{
          symbol: "NEWFLG",
          filed_at: DateTime.utc_now(),
          url: "https://www.sec.gov/Archives/edgar/data/500/newnew/index.htm"
        })

      add_to_universe(old.ticker_id)
      add_to_universe(new_filing.ticker_id)

      # Track which Filings the worker hit by recording paths
      parent = self()

      stub(fn conn ->
        cond do
          String.contains?(conn.request_path, "/index.json") ->
            send(parent, {:fetched, conn.request_path})

            Req.Test.json(conn, %{
              "directory" => %{"item" => [%{"name" => "x.htm"}]}
            })

          String.contains?(conn.request_path, "/x.htm") ->
            Plug.Conn.send_resp(conn, 200, "<p>body</p>")
        end
      end)

      assert :ok = FilingBodyFetcher.perform(%Oban.Job{})

      # The first index.json fetched should be for the older Filing's URL
      assert_received {:fetched, first_path}
      assert String.contains?(first_path, "/400/oldold/")
    end
  end

  # ── Universe scoping (LON-178) ─────────────────────────────────

  describe "perform/1 — universe scoping" do
    test "fetches filings whose ticker is in the small-cap universe; skips others" do
      in_universe =
        build_filing(%{
          symbol: "INUNI",
          url: "https://www.sec.gov/Archives/edgar/data/600/inuni/index.htm"
        })

      out_of_universe =
        build_filing(%{
          symbol: "OUTUNI",
          url: "https://www.sec.gov/Archives/edgar/data/700/outuni/index.htm"
        })

      add_to_universe(in_universe.ticker_id)

      # Stub only the in-universe filing's paths. If the worker tries to
      # fetch the out-of-universe filing, the missing stub clause
      # surfaces as an error and fails the test — same proof shape as
      # the idempotency test above.
      stub(fn conn ->
        cond do
          String.contains?(conn.request_path, "/600/inuni/index.json") ->
            Req.Test.json(conn, %{"directory" => %{"item" => [%{"name" => "form.htm"}]}})

          String.contains?(conn.request_path, "/600/inuni/form.htm") ->
            Plug.Conn.send_resp(conn, 200, "<p>In-universe body.</p>")
        end
      end)

      assert :ok = FilingBodyFetcher.perform(%Oban.Job{})

      # In-universe filing got a body
      assert {:ok, raw} = Filings.get_filing_raw(in_universe.id, authorize?: false)
      assert raw.raw_text =~ "In-universe body"

      # Out-of-universe filing was not fetched
      assert {:error, _} = Filings.get_filing_raw(out_of_universe.id, authorize?: false)
    end

    test "returns :ok with no work when the universe is empty" do
      # Filing exists but its ticker isn't in the universe — soft no-op.
      _orphan =
        build_filing(%{
          symbol: "LONELY",
          url: "https://www.sec.gov/Archives/edgar/data/800/lonely/index.htm"
        })

      # No stub. Absence of stub + no fetch attempt = test passes.
      assert :ok = FilingBodyFetcher.perform(%Oban.Job{})
    end

    test "ignores membership rows whose is_active is false" do
      filing =
        build_filing(%{
          symbol: "INACTIVE",
          url: "https://www.sec.gov/Archives/edgar/data/900/inactive/index.htm"
        })

      add_to_universe(filing.ticker_id)

      # Deactivate the membership via the dedicated bulk-update action,
      # mirroring `FilingAnalysisWorkerTest`'s `is_active = false` case.
      require Ash.Query

      LongOrShort.Tickers.SmallCapUniverseMembership
      |> Ash.Query.filter(ticker_id == ^filing.ticker_id)
      |> Ash.bulk_update!(:deactivate, %{}, authorize?: false)

      # No stub — deactivated membership means no fetch should occur.
      assert :ok = FilingBodyFetcher.perform(%Oban.Job{})
      assert {:error, _} = Filings.get_filing_raw(filing.id, authorize?: false)
    end
  end
end
