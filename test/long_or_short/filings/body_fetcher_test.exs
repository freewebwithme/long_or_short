defmodule LongOrShort.Filings.BodyFetcherTest do
  @moduledoc """
  Tests for `LongOrShort.Filings.BodyFetcher`.

  Uses `Req.Test` plug stubs (configured in `config/test.exs`) to
  intercept HTTP. No real SEC traffic.
  """

  use ExUnit.Case, async: false

  alias LongOrShort.Filings.{BodyFetcher, Filing}

  defp filing(attrs \\ %{}) do
    defaults = %{
      id: "00000000-0000-0000-0000-000000000001",
      source: :sec_edgar,
      filing_type: :_8k,
      filing_subtype: nil,
      external_id: "test-1",
      filer_cik: "0001234567",
      filed_at: DateTime.utc_now(),
      url:
        "https://www.sec.gov/Archives/edgar/data/123/0001234567-26-000001/0001234567-26-000001-index.htm",
      ticker_id: "00000000-0000-0000-0000-000000000002"
    }

    struct(Filing, Map.merge(defaults, attrs))
  end

  defp stub(fun), do: Req.Test.stub(LongOrShort.Filings.BodyFetcher, fun)

  @index_path "/Archives/edgar/data/123/0001234567-26-000001/index.json"

  describe "fetch_body/1 — input validation" do
    test "filing without URL returns :no_url" do
      assert {:error, :no_url} = BodyFetcher.fetch_body(filing(%{url: nil}))
    end

    test "malformed URL returns :invalid_url" do
      assert {:error, :invalid_url} = BodyFetcher.fetch_body(filing(%{url: "not-a-url"}))
    end
  end

  describe "fetch_body/1 — happy path" do
    test "fetches index.json then primary document, returns text + hash" do
      stub(fn conn ->
        case conn.request_path do
          @index_path ->
            Req.Test.json(conn, %{
              "directory" => %{
                "item" => [
                  %{"name" => "R1.htm"},
                  %{"name" => "ex_99.htm"},
                  %{"name" => "form8-k.htm"}
                ]
              }
            })

          "/Archives/edgar/data/123/0001234567-26-000001/form8-k.htm" ->
            Plug.Conn.send_resp(
              conn,
              200,
              "<html><body><p>Filing content here.</p></body></html>"
            )
        end
      end)

      assert {:ok, text, hash} = BodyFetcher.fetch_body(filing())
      assert text =~ "Filing content here"
      assert is_binary(hash)
      # SHA-256 hex = 64 chars
      assert byte_size(hash) == 64
      assert hash =~ ~r/^[a-f0-9]{64}$/
    end

    test "primary doc selection skips R*, ex_*, and *index*" do
      stub(fn conn ->
        case conn.request_path do
          @index_path ->
            Req.Test.json(conn, %{
              "directory" => %{
                "item" => [
                  %{"name" => "R1.htm"},
                  %{"name" => "R10.htm"},
                  %{"name" => "ex_99_1.htm"},
                  %{"name" => "0001234567-26-000001-index.htm"},
                  %{"name" => "primary.htm"}
                ]
              }
            })

          "/Archives/edgar/data/123/0001234567-26-000001/primary.htm" ->
            Plug.Conn.send_resp(conn, 200, "<p>Primary content.</p>")
        end
      end)

      assert {:ok, text, _hash} = BodyFetcher.fetch_body(filing())
      assert text =~ "Primary content"
    end
  end

  describe "fetch_body/1 — error paths" do
    test "no eligible primary doc returns :no_primary_document" do
      stub(fn conn ->
        case conn.request_path do
          @index_path ->
            Req.Test.json(conn, %{
              "directory" => %{
                "item" => [
                  %{"name" => "R1.htm"},
                  %{"name" => "ex_99.htm"},
                  %{"name" => "0001234567-26-000001-index.htm"}
                ]
              }
            })
        end
      end)

      assert {:error, :no_primary_document} = BodyFetcher.fetch_body(filing())
    end

    test "non-200 on index.json returns http_status error" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 404, "") end)

      assert {:error, {:http_status, 404}} = BodyFetcher.fetch_body(filing())
    end

    test "non-200 on primary doc returns http_status error" do
      stub(fn conn ->
        case conn.request_path do
          @index_path ->
            Req.Test.json(conn, %{
              "directory" => %{"item" => [%{"name" => "form8-k.htm"}]}
            })

          "/Archives/edgar/data/123/0001234567-26-000001/form8-k.htm" ->
            Plug.Conn.send_resp(conn, 503, "")
        end
      end)

      assert {:error, {:http_status, 503}} = BodyFetcher.fetch_body(filing())
    end

    test "invalid JSON in index returns :invalid_json" do
      stub(fn conn ->
        Plug.Conn.put_resp_header(conn, "content-type", "text/plain")
        |> Plug.Conn.send_resp(200, "not json {{{")
      end)

      assert {:error, :invalid_json} = BodyFetcher.fetch_body(filing())
    end

    test "empty primary doc returns :empty_body" do
      stub(fn conn ->
        case conn.request_path do
          @index_path ->
            Req.Test.json(conn, %{
              "directory" => %{"item" => [%{"name" => "form8-k.htm"}]}
            })

          "/Archives/edgar/data/123/0001234567-26-000001/form8-k.htm" ->
            Plug.Conn.send_resp(conn, 200, "")
        end
      end)

      assert {:error, :empty_body} = BodyFetcher.fetch_body(filing())
    end
  end

  describe "fetch_body/1 — content_hash" do
    test "deterministic across identical content" do
      stub(fn conn ->
        case conn.request_path do
          @index_path ->
            Req.Test.json(conn, %{
              "directory" => %{"item" => [%{"name" => "form.htm"}]}
            })

          "/Archives/edgar/data/123/0001234567-26-000001/form.htm" ->
            Plug.Conn.send_resp(conn, 200, "<p>Stable content.</p>")
        end
      end)

      assert {:ok, _, hash1} = BodyFetcher.fetch_body(filing())
      assert {:ok, _, hash2} = BodyFetcher.fetch_body(filing())
      assert hash1 == hash2
    end
  end
end
