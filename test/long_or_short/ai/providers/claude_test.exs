defmodule LongOrShort.AI.Providers.ClaudeTest do
  use ExUnit.Case, async: true

  alias LongOrShort.AI.Providers.Claude

  @messages [%{role: "user", content: "hi"}]
  @tools [
    %{
      name: "report_repetition_analysis",
      description: "test",
      input_schema: %{type: "object", properties: %{}}
    }
  ]

  setup do
    # Ensure :anthropic_api_key is set for the duration of the test.
    prior = Application.get_env(:long_or_short, :anthropic_api_key)
    Application.put_env(:long_or_short, :anthropic_api_key, "test-key")

    on_exit(fn ->
      if prior do
        Application.put_env(:long_or_short, :anthropic_api_key, prior)
      else
        Application.delete_env(:long_or_short, :anthropic_api_key)
      end
    end)

    :ok
  end

  defp stub(fun), do: Req.Test.stub(LongOrShort.AI.Providers.Claude, fun)

  defp tool_use_response(name, input, opts \\ []) do
    %{
      "content" => [
        %{"type" => "tool_use", "id" => "tu_1", "name" => name, "input" => input}
      ],
      "usage" => %{
        "input_tokens" => Keyword.get(opts, :input_tokens, 100),
        "output_tokens" => Keyword.get(opts, :output_tokens, 50)
      }
    }
  end

  describe "call/3 — request shape" do
    test "POSTs to /v1/messages with the expected headers and body" do
      stub(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v1/messages"

        assert Plug.Conn.get_req_header(conn, "x-api-key") == ["test-key"]
        assert Plug.Conn.get_req_header(conn, "anthropic-version") == ["2023-06-01"]
        assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]

        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)

        assert body["model"] == "claude-sonnet-4-6"
        assert body["max_tokens"] == 4096
        assert body["messages"] == [%{"role" => "user", "content" => "hi"}]
        assert is_list(body["tools"])
        assert body["tool_choice"] == %{"type" => "auto"}

        Req.Test.json(conn, tool_use_response("report_repetition_analysis", %{"ok" => true}))
      end)

      assert {:ok, _} = Claude.call(@messages, @tools)
    end

    test "opts override default model and max_tokens" do
      stub(fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)

        assert body["model"] == "claude-haiku-4-5-20251001"
        assert body["max_tokens"] == 256

        Req.Test.json(conn, tool_use_response("t", %{}))
      end)

      Claude.call(@messages, @tools, model: "claude-haiku-4-5-20251001", max_tokens: 256)
    end

    test "opts can force a specific tool_choice" do
      stub(fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)

        assert body["tool_choice"] == %{"type" => "tool", "name" => "report_repetition_analysis"}

        Req.Test.json(conn, tool_use_response("report_repetition_analysis", %{}))
      end)

      Claude.call(@messages, @tools,
        tool_choice: %{type: "tool", name: "report_repetition_analysis"}
      )
    end
  end

  describe "call/3 — response normalization" do
    test "extracts tool_calls and usage on a clean tool_use response" do
      stub(fn conn ->
        Req.Test.json(
          conn,
          tool_use_response(
            "report_repetition_analysis",
            %{"is_repetition" => true, "repetition_count" => 2},
            input_tokens: 1234,
            output_tokens: 567
          )
        )
      end)

      assert {:ok, response} = Claude.call(@messages, @tools)

      assert response.tool_calls == [
               %{
                 name: "report_repetition_analysis",
                 input: %{"is_repetition" => true, "repetition_count" => 2}
               }
             ]

      assert is_nil(response.text)
      assert response.usage == %{input_tokens: 1234, output_tokens: 567}
    end

    test "returns text-only response with empty tool_calls list" do
      stub(fn conn ->
        Req.Test.json(conn, %{
          "content" => [%{"type" => "text", "text" => "Hello there."}],
          "usage" => %{"input_tokens" => 5, "output_tokens" => 3}
        })
      end)

      assert {:ok, %{tool_calls: [], text: "Hello there."}} = Claude.call(@messages, @tools)
    end

    test "concatenates multiple text blocks" do
      stub(fn conn ->
        Req.Test.json(conn, %{
          "content" => [
            %{"type" => "text", "text" => "Part 1."},
            %{"type" => "text", "text" => " Part 2."}
          ],
          "usage" => %{}
        })
      end)

      assert {:ok, %{text: "Part 1. Part 2."}} = Claude.call(@messages, @tools)
    end

    test "extracts multiple tool_calls when present" do
      stub(fn conn ->
        Req.Test.json(conn, %{
          "content" => [
            %{"type" => "tool_use", "id" => "1", "name" => "a", "input" => %{}},
            %{"type" => "tool_use", "id" => "2", "name" => "b", "input" => %{"x" => 1}}
          ],
          "usage" => %{}
        })
      end)

      assert {:ok, %{tool_calls: [%{name: "a"}, %{name: "b", input: %{"x" => 1}}]}} =
               Claude.call(@messages, @tools)
    end

    test "returns {:error, {:invalid_response, _}} when content is missing" do
      stub(fn conn ->
        Req.Test.json(conn, %{"unexpected" => "shape"})
      end)

      assert {:error, {:invalid_response, %{"unexpected" => "shape"}}} =
               Claude.call(@messages, @tools)
    end
  end

  describe "call/3 — error handling" do
    test "4xx returns {:error, {:http_error, status, body}}" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"error" => %{"type" => "invalid_request_error"}})
      end)

      assert {:error, {:http_error, 400, %{"error" => %{"type" => "invalid_request_error"}}}} =
               Claude.call(@messages, @tools)
    end

    test "5xx returns {:error, {:http_error, status, body}}" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(503)
        |> Req.Test.json(%{"error" => "server overloaded"})
      end)

      assert {:error, {:http_error, 503, _}} = Claude.call(@messages, @tools)
    end

    test "429 returns {:error, {:rate_limited, retry_after}}" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "30")
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{"error" => "rate limited"})
      end)

      assert {:error, {:rate_limited, "30"}} = Claude.call(@messages, @tools)
    end

    test "429 without retry-after still yields :rate_limited with nil" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{})
      end)

      assert {:error, {:rate_limited, nil}} = Claude.call(@messages, @tools)
    end

    test "transport failure becomes {:error, {:network_error, reason}}" do
      stub(fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, {:network_error, :econnrefused}} = Claude.call(@messages, @tools)
    end

    test "missing API key short-circuits with :no_api_key" do
      Application.delete_env(:long_or_short, :anthropic_api_key)

      assert {:error, :no_api_key} = Claude.call(@messages, @tools)
    end

    test "empty API key counts as missing" do
      Application.put_env(:long_or_short, :anthropic_api_key, "")
      assert {:error, :no_api_key} = Claude.call(@messages, @tools)
    end
  end

  # ──────────────────────────────────────────────────────────────────
  # Real-API smoke test. Skipped by default. To run:
  #
  #   ANTHROPIC_API_KEY=sk-... mix test --include external
  #
  # Hits the real Anthropic API and costs a few input tokens.
  # ──────────────────────────────────────────────────────────────────
  describe "call/3 — real API (external)" do
    @describetag :external

    setup do
      Application.put_env(
        :long_or_short,
        :anthropic_api_key,
        System.fetch_env!("ANTHROPIC_API_KEY")
      )

      # Skip the test plug for this suite — go to the real network.
      prior = Application.get_env(:long_or_short, LongOrShort.AI.Providers.Claude)

      Application.put_env(
        :long_or_short,
        LongOrShort.AI.Providers.Claude,
        Keyword.delete(prior, :req_plug)
      )

      on_exit(fn ->
        Application.put_env(:long_or_short, LongOrShort.AI.Providers.Claude, prior)
      end)

      :ok
    end

    test "round-trips a tool_use response end-to-end" do
      assert {:ok, %{tool_calls: [_ | _]}} =
               Claude.call(
                 [%{role: "user", content: "Use the test tool with x=1."}],
                 [
                   %{
                     name: "test",
                     description: "Echoes a number.",
                     input_schema: %{
                       type: "object",
                       properties: %{x: %{type: "integer"}},
                       required: ["x"]
                     }
                   }
                 ],
                 tool_choice: %{type: "tool", name: "test"}
               )
    end
  end
end
