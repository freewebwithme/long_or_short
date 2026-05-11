defmodule LongOrShort.AI.Providers.Qwen do
  @moduledoc """
  Alibaba DashScope (Qwen) provider for `LongOrShort.AI.Provider` —
  LON-104.

  Wraps DashScope's OpenAI-compatible Chat Completions endpoint with
  a region-switchable base URL (Singapore free tier for dev/test,
  US Virginia pay-as-you-go for production) and translates between
  the app's normalized provider contract and OpenAI wire format.

  ## Configuration

      # config/config.exs (defaults — no secrets)
      config :long_or_short, #{inspect(__MODULE__)},
        model: "qwen3-max",
        max_tokens: 4096,
        base_urls: %{
          singapore: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
          us: "https://dashscope-us.aliyuncs.com/compatible-mode/v1"
        }

      # config/runtime.exs (existing pattern; reads env at boot)
      config :long_or_short,
        qwen_region: env!("QWEN_REGION", :string, "singapore"),
        qwen_api_key: env!("QWEN_API_KEY", :string, nil)

  ## Region selection

  `:qwen_region` config (`:singapore` / `:us` as atom, or the matching
  string from env) picks the base URL at request time. **API keys
  are not interchangeable across regions** — each region issues its
  own key from its own console. Mixing them yields 401.

  Region is configured per environment, not per request. There is no
  failover or routing between regions — premature for current scale
  and out of scope per the ticket.

  ## OpenAI-compat wire format translation

  Qwen's DashScope compatible-mode endpoint accepts OpenAI Chat
  Completions request bodies. This provider does the translation
  both ways:

    * **Tools outbound** —
      `%{name, description, input_schema}` (the app's flat
      `t:LongOrShort.AI.Provider.tool_spec/0`) →
      `%{type: "function", function: %{name, description, parameters: ...}}`.
    * **Tool calls inbound** —
      `choices[0].message.tool_calls[]` (each with
      `function.arguments` as a JSON-encoded string) →
      `[%{name: ..., input: %{...}}]` (arguments decoded to a map).
      Same shape Claude's normalizer emits.
    * **Usage** — `prompt_tokens` / `completion_tokens` →
      `:input_tokens` / `:output_tokens`.

  System messages stay inside the `messages` array per OpenAI
  convention — no top-level `system` parameter (that's Anthropic).
  This means `Prompts.NewsAnalysis` can keep emitting `[system, user]`
  unchanged.

  ## Prompt caching

  DashScope's compatible-mode endpoint does **not** support
  Anthropic-style `cache_control` markers. Whatever server-side
  caching Qwen does is automatic and opaque. The
  mark-last-cacheable logic in the Claude provider has no
  counterpart here.

  ## Errors

  Same `{:error, reason}` shape as the Claude provider so callers
  stay provider-agnostic:

    * `{:http_error, status, body}` — non-2xx response
    * `{:rate_limited, retry_after}` — 429 (`retry_after` may be nil)
    * `{:network_error, reason}` — transport failure
    * `{:invalid_response, body}` — JSON shape unexpected
    * `:no_api_key` — `:qwen_api_key` unset
  """
  @behaviour LongOrShort.AI.Provider

  @path "chat/completions"
  @receive_timeout :timer.seconds(60)

  @impl true
  def call(messages, tools, opts \\ []) do
    with {:ok, key} <- api_key(),
         body = build_body(messages, tools, opts),
         {:ok, response} <- post(key, body) do
      handle_response(response)
    end
  end

  # ─── HTTP ──────────────────────────────────────────────────────────

  defp post(api_key, body) do
    case Req.post(client(api_key), url: @path, json: body) do
      {:ok, %Req.Response{} = response} ->
        {:ok, response}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, {:network_error, reason}}

      {:error, reason} ->
        {:error, {:network_error, reason}}
    end
  end

  defp client(api_key) do
    config = config()

    base =
      Req.new(
        base_url: region_base_url(config),
        headers: headers(api_key),
        receive_timeout: @receive_timeout,
        retry: false
      )

    case Keyword.get(config, :req_plug) do
      nil -> base
      plug -> Req.merge(base, plug: plug)
    end
  end

  defp region_base_url(config) do
    region = Application.fetch_env!(:long_or_short, :qwen_region) |> to_region_atom()
    base_urls = Keyword.fetch!(config, :base_urls)

    case Map.fetch(base_urls, region) do
      {:ok, url} ->
        url

      :error ->
        raise ArgumentError,
              "no base URL configured for Qwen region #{inspect(region)} — " <>
                "check :base_urls under #{inspect(__MODULE__)}"
    end
  end

  defp to_region_atom(:singapore), do: :singapore
  defp to_region_atom(:us), do: :us
  defp to_region_atom("singapore"), do: :singapore
  defp to_region_atom("us"), do: :us

  defp to_region_atom(other),
    do:
      raise(
        ArgumentError,
        "unknown Qwen region #{inspect(other)} -- expected :singapore or :us"
      )

  defp headers(api_key) do
    [
      {"authorization", "Bearer #{api_key}"},
      {"content-type", "application/json"}
    ]
  end

  # ─── Request body ─────────────────────────────────────────────────

  defp build_body(messages, tools, opts) do
    config = config()

    base = %{
      model: Keyword.get(opts, :model) || Keyword.fetch!(config, :model),
      max_tokens: Keyword.get(opts, :max_tokens) || Keyword.fetch!(config, :max_tokens),
      messages: messages,
      tool_choice: Keyword.get(opts, :tool_choice, "auto")
    }

    case tools do
      [] -> base
      _ -> Map.put(base, :tools, translate_tools(tools))
    end
  end

  # Translates the app's flat tool spec into OpenAI function-calling
  # format. `input_schema` becomes `function.parameters`; everything
  # else moves under `function`.
  defp translate_tools(tools) do
    Enum.map(tools, fn t ->
      %{
        type: "function",
        function: %{
          name: t.name,
          description: t.description,
          parameters: t.input_schema
        }
      }
    end)
  end

  # ─── Response handling ────────────────────────────────────────────

  defp handle_response(%Req.Response{status: 200, body: body}) when is_map(body) do
    normalize(body)
  end

  defp handle_response(%Req.Response{status: 429, headers: headers, body: _}) do
    {:error, {:rate_limited, retry_after(headers)}}
  end

  defp handle_response(%Req.Response{status: status, body: body}) when status in 400..599 do
    {:error, {:http_error, status, body}}
  end

  defp handle_response(%Req.Response{body: body}) do
    {:error, {:invalid_response, body}}
  end

  defp normalize(%{"choices" => [choice | _]} = body) do
    message = Map.get(choice, "message") || %{}
    usage = extract_usage(body)

    :telemetry.execute(
      [:long_or_short, :ai, :qwen, :call],
      usage,
      %{}
    )

    {:ok,
     %{
       tool_calls: extract_tool_calls(message),
       text: extract_text(message),
       usage: usage
     }}
  end

  defp normalize(body), do: {:error, {:invalid_response, body}}

  defp extract_tool_calls(%{"tool_calls" => calls}) when is_list(calls) do
    Enum.flat_map(calls, fn
      %{"function" => %{"name" => name, "arguments" => args}} ->
        [%{name: name, input: decode_arguments(args)}]

      _ ->
        []
    end)
  end

  defp extract_tool_calls(_), do: []

  # Tool-call arguments come back as a JSON-encoded string per OpenAI
  # convention. Decode into a map so callers see the same shape they
  # get from Claude's tool_use blocks (which already deliver an input
  # map). Empty / malformed → `%{}` (caller's enum validation catches
  # the missing fields).
  defp decode_arguments(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp decode_arguments(map) when is_map(map), do: map
  defp decode_arguments(_), do: %{}

  defp extract_text(%{"content" => content}) when is_binary(content) and content != "",
    do: content

  defp extract_text(_), do: nil

  # Returns the same 4-key shape Claude emits so the telemetry handler
  # and downstream usage trackers (LON-35 epic) don't need a
  # provider-specific branch. Qwen's compat endpoint does not emit
  # cache_creation/read fields — those default to 0.
  defp extract_usage(body) do
    usage = Map.get(body, "usage") || %{}

    %{
      input_tokens: Map.get(usage, "prompt_tokens", 0),
      output_tokens: Map.get(usage, "completion_tokens", 0),
      cache_creation_input_tokens: 0,
      cache_read_input_tokens: 0
    }
  end

  defp retry_after(%{} = headers) do
    case Map.get(headers, "retry-after") do
      [value | _] -> value
      _ -> nil
    end
  end

  defp retry_after(_), do: nil

  # ─── Config helpers ────────────────────────────────────────────────

  defp config, do: Application.get_env(:long_or_short, __MODULE__, [])

  defp api_key do
    case Application.fetch_env(:long_or_short, :qwen_api_key) do
      {:ok, key} when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :no_api_key}
    end
  end
end
