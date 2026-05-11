defmodule LongOrShort.AI.Providers.QwenTest do
  @moduledoc """
  Unit tests for `LongOrShort.AI.Providers.Qwen` -- LON-104.

  Mirrors the Claude provider test pattern. Stubs HTTP via `Req.Test`
  routed through the `:req_plug` config set in `config/test.exs`.
  No real DashScope traffic.
  """

  use ExUnit.Case, async: false

  alias LongOrShort.AI.Providers.Qwen

  @messages [%{role: "user", content: "hi"}]
  @tools [
    %{
      name: "record_news_analysis",
      description: "test",
      input_schema: %{type: "object", properties: %{}}
    }
  ]

  setup do
    # Ensure :qwen_api_key + :qwen_region are set for the duration of
    # each test. Region defaults to :singapore in config.exs but other
    # tests may have mutated it.
    prior_key = Application.get_env(:long_or_short, :qwen_api_key)
    prior_region = Application.get_env(:long_or_short, :qwen_region)

    Application.put_env(:long_or_short, :qwen_api_key, "test-key")
    Application.put_env(:long_or_short, :qwen_region, :singapore)

    on_exit(fn ->
      restore_env(:qwen_api_key, prior_key)
      restore_env(:qwen_region, prior_region)
    end)

    :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:long_or_short, key)
  defp restore_env(key, value), do: Application.put_env(:long_or_short, key, value)

  defp stub(fun), do: Req.Test.stub(LongOrShort.AI.Providers.Qwen, fun)

  defp tool_call_response(name, input, opts \\ []) do
    arguments = Jason.encode!(input)

    usage =
      %{
        "prompt_tokens" => Keyword.get(opts, :prompt_tokens, 100),
        "completion_tokens" => Keyword.get(opts, :completion_tokens, 50)
      }

    %{
      "id" => "chatcmpl-test",
      "object" => "chat.completion",
      "choices" => [
        %{
          "index" => 0,
          "message" => %{
            "role" => "assistant",
            "content" => Keyword.get(opts, :content),
            "tool_calls" => [
              %{
                "id" => "call_test",
                "type" => "function",
                "function" => %{
                  "name" => name,
                  "arguments" => arguments
                }
              }
            ]
          }
        }
      ],
      "usage" => usage
    }
  end

  describe "call/3 -- request shape" do
    test "POSTs to chat/completions with Bearer auth and OpenAI body" do
      stub(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/compatible-mode/v1/chat/completions"

        auth =
          conn.req_headers
          |> Enum.find_value(fn {k, v} -> if k == "authorization", do: v end)

        assert auth == "Bearer test-key"

        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)

        assert body["model"] == "qwen3-max"
        assert body["max_tokens"] == 4096
        assert body["messages"] == [%{"role" => "user", "content" => "hi"}]
        assert body["tool_choice"] == "auto"

        Req.Test.json(conn, tool_call_response("record_news_analysis", %{"ok" => true}))
      end)

      assert {:ok, _} = Qwen.call(@messages, @tools)
    end

    test "respects :model opts override" do
      stub(fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)

        assert body["model"] == "qwen3-plus"

        Req.Test.json(conn, tool_call_response("t", %{}))
      end)

      assert {:ok, _} = Qwen.call(@messages, @tools, model: "qwen3-plus")
    end

    test "omits tools key when none supplied" do
      stub(fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)

        refute Map.has_key?(body, "tools")

        Req.Test.json(conn, tool_call_response("noop", %{}))
      end)

      assert {:ok, _} = Qwen.call(@messages, [])
    end
  end

  describe "call/3 -- tool spec translation" do
    test "translates flat tool spec into OpenAI function-calling format" do
      stub(fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)

        assert [tool] = body["tools"]
        assert tool["type"] == "function"
        assert tool["function"]["name"] == "record_news_analysis"
        assert tool["function"]["description"] == "test"
        assert tool["function"]["parameters"] == %{"type" => "object", "properties" => %{}}

        Req.Test.json(conn, tool_call_response("record_news_analysis", %{}))
      end)

      assert {:ok, _} = Qwen.call(@messages, @tools)
    end

    test "translates multiple tools, preserving order" do
      tools = [
        %{name: "first", description: "f", input_schema: %{type: "object", properties: %{}}},
        %{name: "second", description: "s", input_schema: %{type: "object", properties: %{}}}
      ]

      stub(fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)

        assert [t1, t2] = body["tools"]
        assert t1["function"]["name"] == "first"
        assert t2["function"]["name"] == "second"

        Req.Test.json(conn, tool_call_response("first", %{}))
      end)

      assert {:ok, _} = Qwen.call(@messages, tools)
    end
  end

  describe "call/3 -- region URL" do
    test "Singapore region hits dashscope-intl host" do
      Application.put_env(:long_or_short, :qwen_region, :singapore)

      stub(fn conn ->
        assert conn.host == "dashscope-intl.aliyuncs.com"
        Req.Test.json(conn, tool_call_response("t", %{}))
      end)

      assert {:ok, _} = Qwen.call(@messages, @tools)
    end

    test "US region hits dashscope-us host" do
      Application.put_env(:long_or_short, :qwen_region, :us)

      stub(fn conn ->
        assert conn.host == "dashscope-us.aliyuncs.com"
        Req.Test.json(conn, tool_call_response("t", %{}))
      end)

      assert {:ok, _} = Qwen.call(@messages, @tools)
    end

    test "string region 'singapore' resolves to :singapore" do
      # Runtime env reads come in as strings -- provider's
      # to_region_atom/1 must accept either form.
      Application.put_env(:long_or_short, :qwen_region, "singapore")

      stub(fn conn ->
        assert conn.host == "dashscope-intl.aliyuncs.com"
        Req.Test.json(conn, tool_call_response("t", %{}))
      end)

      assert {:ok, _} = Qwen.call(@messages, @tools)
    end

    test "unknown region raises at request time" do
      Application.put_env(:long_or_short, :qwen_region, :tokyo)

      assert_raise ArgumentError, ~r/unknown Qwen region/, fn ->
        Qwen.call(@messages, @tools)
      end
    end
  end

  describe "call/3 -- response normalization" do
    test "extracts tool_calls with JSON-decoded arguments" do
      stub(fn conn ->
        Req.Test.json(
          conn,
          tool_call_response("record_news_analysis", %{"verdict" => "trade", "score" => 7})
        )
      end)

      assert {:ok, %{tool_calls: [call]}} = Qwen.call(@messages, @tools)
      assert call.name == "record_news_analysis"
      assert call.input == %{"verdict" => "trade", "score" => 7}
    end

    test "handles malformed arguments gracefully (empty map)" do
      bad_response = %{
        "choices" => [
          %{
            "message" => %{
              "tool_calls" => [
                %{
                  "function" => %{
                    "name" => "broken",
                    "arguments" => "{not valid json"
                  }
                }
              ]
            }
          }
        ],
        "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1}
      }

      stub(fn conn -> Req.Test.json(conn, bad_response) end)

      assert {:ok, %{tool_calls: [call]}} = Qwen.call(@messages, @tools)
      assert call.input == %{}
    end

    test "extracts assistant text when present (no tool call branch)" do
      stub(fn conn ->
        Req.Test.json(conn, %{
          "choices" => [%{"message" => %{"content" => "hello world"}}],
          "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1}
        })
      end)

      assert {:ok, %{text: "hello world", tool_calls: []}} = Qwen.call(@messages, @tools)
    end

    test "nil content becomes nil text" do
      stub(fn conn ->
        Req.Test.json(conn, tool_call_response("t", %{}, content: nil))
      end)

      assert {:ok, %{text: nil}} = Qwen.call(@messages, @tools)
    end

    test "maps usage prompt_tokens/completion_tokens to input/output, fills cache fields with 0" do
      # Cache fields mirror the Claude provider's shape so downstream
      # token-accounting code stays provider-agnostic (LON-35 epic).
      stub(fn conn ->
        Req.Test.json(
          conn,
          tool_call_response("t", %{}, prompt_tokens: 1234, completion_tokens: 567)
        )
      end)

      assert {:ok, %{usage: usage}} = Qwen.call(@messages, @tools)

      assert usage == %{
               input_tokens: 1234,
               output_tokens: 567,
               cache_creation_input_tokens: 0,
               cache_read_input_tokens: 0
             }
    end

    test "missing usage entirely yields zeros (defensive default)" do
      stub(fn conn ->
        Req.Test.json(conn, %{
          "choices" => [%{"message" => %{"content" => "ok"}}]
        })
      end)

      assert {:ok, %{usage: %{input_tokens: 0, output_tokens: 0}}} =
               Qwen.call(@messages, @tools)
    end
  end

  describe "call/3 -- error handling" do
    test "429 with Retry-After returns {:rate_limited, value}" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "30")
        |> Plug.Conn.send_resp(429, ~s({"error":"too many"}))
      end)

      assert {:error, {:rate_limited, "30"}} = Qwen.call(@messages, @tools)
    end

    test "4xx returns {:http_error, status, body}" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(400, ~s({"error":"bad request"}))
      end)

      assert {:error, {:http_error, 400, body}} = Qwen.call(@messages, @tools)
      assert body == %{"error" => "bad request"}
    end

    test "5xx returns {:http_error, status, body}" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 500, "internal error") end)
      assert {:error, {:http_error, 500, _}} = Qwen.call(@messages, @tools)
    end

    # Transport-error path is covered by the Claude provider's
    # identical `case Req.post/2 do {:error, %TransportError{}} -> ...`
    # branch (this provider mirrors that). Driving the same path
    # through `Req.Test` reliably in a unit test requires
    # `Req.Test.transport_error/2` plumbing not yet wired here -- skip.

    test "missing api key returns :no_api_key" do
      Application.delete_env(:long_or_short, :qwen_api_key)

      assert {:error, :no_api_key} = Qwen.call(@messages, @tools)
    end

    test "empty api key (unset env converted to empty string) returns :no_api_key" do
      Application.put_env(:long_or_short, :qwen_api_key, "")
      assert {:error, :no_api_key} = Qwen.call(@messages, @tools)
    end

    test "200 with no choices returns {:invalid_response, body}" do
      stub(fn conn -> Req.Test.json(conn, %{"id" => "x"}) end)
      assert {:error, {:invalid_response, _}} = Qwen.call(@messages, @tools)
    end
  end
end
