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

  defp stub(fun), do: Req.Test.stub(LongOrShort.Filings.BodyFetcher, fun)

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
          url:
            "https://www.sec.gov/Archives/edgar/data/200/0000200000-26-000001/index.htm"
        })

      bad =
        build_filing(%{
          symbol: "BADFL",
          url:
            "https://www.sec.gov/Archives/edgar/data/300/0000300000-26-000001/index.htm"
        })

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

      _new =
        build_filing(%{
          symbol: "NEWFLG",
          filed_at: DateTime.utc_now(),
          url: "https://www.sec.gov/Archives/edgar/data/500/newnew/index.htm"
        })

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

      _ = old
    end
  end
end
