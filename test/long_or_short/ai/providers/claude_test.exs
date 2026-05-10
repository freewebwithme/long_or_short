defmodule LongOrShort.AI.Providers.ClaudeTest do
  use ExUnit.Case, async: true

  alias LongOrShort.AI.Providers.Claude

  @messages [%{role: "user", content: "hi"}]
  @tools [
    %{
      name: "record_news_analysis",
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
    usage =
      %{
        "input_tokens" => Keyword.get(opts, :input_tokens, 100),
        "output_tokens" => Keyword.get(opts, :output_tokens, 50)
      }
      |> maybe_put("cache_creation_input_tokens", opts[:cache_creation_input_tokens])
      |> maybe_put("cache_read_input_tokens", opts[:cache_read_input_tokens])

    %{
      "content" => [
        %{"type" => "tool_use", "id" => "tu_1", "name" => name, "input" => input}
      ],
      "usage" => usage
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

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

        Req.Test.json(conn, tool_use_response("record_news_analysis", %{"ok" => true}))
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

        assert body["tool_choice"] == %{"type" => "tool", "name" => "record_news_analysis"}

        Req.Test.json(conn, tool_use_response("record_news_analysis", %{}))
      end)

      Claude.call(@messages, @tools, tool_choice: %{type: "tool", name: "record_news_analysis"})
    end
  end

  describe "call/3 — prompt caching (LON-38)" do
    test "wraps the system message in a cache-tagged content block" do
      messages = [
        %{role: "system", content: "You are a trader's analyst."},
        %{role: "user", content: "Analyze this article."}
      ]

      stub(fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)

        assert body["system"] == [
                 %{
                   "type" => "text",
                   "text" => "You are a trader's analyst.",
                   "cache_control" => %{"type" => "ephemeral"}
                 }
               ]

        Req.Test.json(conn, tool_use_response("record_news_analysis", %{}))
      end)

      Claude.call(messages, @tools)
    end

    test "omits the system parameter when no system message is provided" do
      stub(fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)

        refute Map.has_key?(body, "system")

        Req.Test.json(conn, tool_use_response("record_news_analysis", %{}))
      end)

      Claude.call(@messages, @tools)
    end

    test "marks only the last tool with cache_control" do
      multi_tools = [
        %{name: "first", description: "x", input_schema: %{type: "object", properties: %{}}},
        %{name: "second", description: "y", input_schema: %{type: "object", properties: %{}}}
      ]

      stub(fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)

        [first, last] = body["tools"]
        refute Map.has_key?(first, "cache_control")
        assert last["cache_control"] == %{"type" => "ephemeral"}

        Req.Test.json(conn, tool_use_response("first", %{}))
      end)

      Claude.call(@messages, multi_tools)
    end

    test "marks the only tool with cache_control when the list has one entry" do
      stub(fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)

        [only] = body["tools"]
        assert only["cache_control"] == %{"type" => "ephemeral"}

        Req.Test.json(conn, tool_use_response("record_news_analysis", %{}))
      end)

      Claude.call(@messages, @tools)
    end
  end

  describe "call/3 — model-agnostic cache markers (LON-120)" do
    # LON-120 investigation found that Haiku 4.5's caching no-op
    # comes from Anthropic's minimum-prefix threshold (4096 tokens
    # vs Sonnet 4.6's 2048), not from any model-specific behavior in
    # our wire body. These tests guard against accidentally adding
    # such model-specific behavior later — every model gets the
    # same cache_control markers, Anthropic decides whether they
    # engage based on prefix size.

    test "Haiku model receives the same cache_control markers as Sonnet on the system block" do
      messages = [
        %{role: "system", content: "You are a trader's analyst."},
        %{role: "user", content: "Analyze this article."}
      ]

      stub(fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)

        assert body["model"] == "claude-haiku-4-5-20251001"

        assert body["system"] == [
                 %{
                   "type" => "text",
                   "text" => "You are a trader's analyst.",
                   "cache_control" => %{"type" => "ephemeral"}
                 }
               ]

        Req.Test.json(conn, tool_use_response("record_news_analysis", %{}))
      end)

      Claude.call(messages, @tools, model: "claude-haiku-4-5-20251001")
    end

    test "Haiku model receives cache_control on the last tool" do
      stub(fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)

        assert body["model"] == "claude-haiku-4-5-20251001"

        [only] = body["tools"]
        assert only["cache_control"] == %{"type" => "ephemeral"}

        Req.Test.json(conn, tool_use_response("record_news_analysis", %{}))
      end)

      Claude.call(@messages, @tools, model: "claude-haiku-4-5-20251001")
    end

    test "Sonnet and Haiku produce identical wire bodies except for the model field" do
      messages = [
        %{role: "system", content: "Stable system prefix."},
        %{role: "user", content: "Per-call user content."}
      ]

      capture = fn model ->
        ref = make_ref()
        parent = self()

        stub(fn conn ->
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          send(parent, {ref, Jason.decode!(raw)})
          Req.Test.json(conn, tool_use_response("record_news_analysis", %{}))
        end)

        Claude.call(messages, @tools, model: model)

        receive do
          {^ref, body} -> body
        after
          0 -> flunk("no captured body for model #{model}")
        end
      end

      sonnet_body = capture.("claude-sonnet-4-6")
      haiku_body = capture.("claude-haiku-4-5-20251001")

      # Drop the model field — that's the only legitimate diff.
      assert Map.delete(sonnet_body, "model") == Map.delete(haiku_body, "model")
    end
  end

  describe "call/3 — usage and telemetry (LON-38)" do
    test "exposes cache token fields when the API returns them" do
      stub(fn conn ->
        Req.Test.json(
          conn,
          tool_use_response("record_news_analysis", %{},
            input_tokens: 50,
            output_tokens: 25,
            cache_creation_input_tokens: 800,
            cache_read_input_tokens: 0
          )
        )
      end)

      assert {:ok, response} = Claude.call(@messages, @tools)

      assert response.usage == %{
               input_tokens: 50,
               output_tokens: 25,
               cache_creation_input_tokens: 800,
               cache_read_input_tokens: 0
             }
    end

    test "defaults cache token fields to 0 when the API omits them" do
      stub(fn conn ->
        Req.Test.json(
          conn,
          tool_use_response("record_news_analysis", %{},
            input_tokens: 100,
            output_tokens: 50
          )
        )
      end)

      assert {:ok, response} = Claude.call(@messages, @tools)

      assert response.usage == %{
               input_tokens: 100,
               output_tokens: 50,
               cache_creation_input_tokens: 0,
               cache_read_input_tokens: 0
             }
    end

    test "emits [:long_or_short, :ai, :claude, :call] telemetry on success" do
      test_pid = self()
      handler_id = "test-claude-call-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:long_or_short, :ai, :claude, :call],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      stub(fn conn ->
        Req.Test.json(
          conn,
          tool_use_response("record_news_analysis", %{},
            input_tokens: 200,
            output_tokens: 75,
            cache_creation_input_tokens: 800,
            cache_read_input_tokens: 0
          )
        )
      end)

      assert {:ok, _} = Claude.call(@messages, @tools)

      assert_receive {:telemetry, measurements, %{}}

      assert measurements == %{
               input_tokens: 200,
               output_tokens: 75,
               cache_creation_input_tokens: 800,
               cache_read_input_tokens: 0
             }
    end

    test "does not emit telemetry on error responses" do
      test_pid = self()
      handler_id = "test-claude-call-error-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:long_or_short, :ai, :claude, :call],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{"error" => "boom"})
      end)

      assert {:error, _} = Claude.call(@messages, @tools)
      refute_receive {:telemetry, _, _}, 100
    end
  end

  describe "call/3 — response normalization" do
    test "extracts tool_calls and usage on a clean tool_use response" do
      stub(fn conn ->
        Req.Test.json(
          conn,
          tool_use_response(
            "record_news_analysis",
            %{"verdict" => "trade", "headline_takeaway" => "Strong catalyst"},
            input_tokens: 1234,
            output_tokens: 567
          )
        )
      end)

      assert {:ok, response} = Claude.call(@messages, @tools)

      assert response.tool_calls == [
               %{
                 name: "record_news_analysis",
                 input: %{"verdict" => "trade", "headline_takeaway" => "Strong catalyst"}
               }
             ]

      assert is_nil(response.text)

      assert response.usage == %{
               input_tokens: 1234,
               output_tokens: 567,
               cache_creation_input_tokens: 0,
               cache_read_input_tokens: 0
             }
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

    test "back-to-back calls write the prompt cache, then read from it" do
      # Sonnet 4.6's minimum cacheable prefix is 2048 tokens. Anthropic
      # silently skips caching below the threshold, so the system block
      # has to be padded comfortably past it for this assertion to be
      # meaningful. ×400 → ~11.2K chars → ~2800 tokens, well clear of
      # the 2048 floor (verified empirically: ×200 → ~1660 tokens →
      # cache_creation_input_tokens came back 0).
      big_system = String.duplicate("Trader analysis instruction. ", 400)

      messages = [
        %{role: "system", content: big_system},
        %{role: "user", content: "Record a verdict for AAPL using the tool."}
      ]

      tools = [
        %{
          name: "record",
          description: "Record a verdict.",
          input_schema: %{
            type: "object",
            properties: %{verdict: %{type: "string"}},
            required: ["verdict"]
          }
        }
      ]

      opts = [tool_choice: %{type: "tool", name: "record"}]

      assert {:ok, %{usage: usage1}} = Claude.call(messages, tools, opts)

      assert usage1.cache_creation_input_tokens > 0,
             "expected cache_creation_input_tokens > 0 on first call, got: #{inspect(usage1)}"

      assert {:ok, %{usage: usage2}} = Claude.call(messages, tools, opts)

      assert usage2.cache_read_input_tokens > 0,
             "expected cache_read_input_tokens > 0 on second call, got: #{inspect(usage2)}"
    end
  end
end
