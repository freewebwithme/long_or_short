defmodule LongOrShort.AI.Providers.Claude do
  @moduledoc """
  Anthropic Claude provider for `LongOrShort.AI.Provider`.

  Calls the Messages API with Tool Use enabled and normalizes the
  response into the shape callers expect (`tool_calls`, `text`, `usage`).

  ## Configuration

      # config/config.exs
      config :long_or_short, #{inspect(__MODULE__)},
        model: "claude-sonnet-4-6",
        max_tokens: 4096,
        base_url: "https://api.anthropic.com",
        anthropic_version: "2023-06-01"

      # config/runtime.exs (existing)
      config :long_or_short, :anthropic_api_key, env!("ANTHROPIC_API_KEY", :string, nil)

  ## Message normalization

    Anthropic's Messages API does not accept `role: "system"` inside the
    `messages` list — system content goes as a top-level `system` parameter.
    This module extracts any system messages from the list, joins their
    content with `\n\n`, and routes them to the right place. Callers can
    pass system messages freely without thinking about provider quirks.

  ## Errors

  All errors are returned as `{:error, reason}`. Retries / backoff are
  the caller's responsibility (see `LongOrShort.Analysis.NewsAnalyzer`,
  LON-27). Possible reasons:

    * `{:http_error, status, body}` — non-2xx response
    * `{:rate_limited, retry_after}` — 429 (`retry_after` may be nil)
    * `{:network_error, reason}` — transport failure
    * `{:invalid_response, body}` — JSON shape unexpected
    * `:no_api_key` — `:anthropic_api_key` is unset

  ## Prompt caching (LON-38)

  The `system` block and the last entry in `tools` are marked with
  `cache_control: %{type: "ephemeral"}`. Anthropic caches the request
  prefix through the last breakpoint in body order
  (`system → tools → messages`), so the static prompt prefix
  (system instructions + tool schema) is cached for ~5 minutes and
  reused at ~10% the input-token cost. The per-article user message is
  always non-cached.

  `usage` returned to callers includes `cache_creation_input_tokens`
  and `cache_read_input_tokens` so callers can observe hit rate. A
  `[:long_or_short, :ai, :claude, :call]` telemetry event is emitted
  on every successful response with the same measurements.

  ### Minimum cacheable prefix (the gotcha)

  Anthropic silently skips caching when the cacheable prefix is below
  a model-specific threshold. The numbers below are pulled from the
  current platform.claude.com prompt-caching docs and verified
  against this app empirically (LON-38 and LON-120):

    * **Sonnet 4.6** — 2048 tokens
    * **Haiku 4.5**  — 4096 tokens
    * **Opus 4.5 / 4.6 / 4.7** — 4096 tokens

  When skipped, the API returns the request normally with
  `cache_creation_input_tokens: 0` and `cache_read_input_tokens: 0` —
  no error, no warning. Verified empirically:

    * Sonnet 4.6 with a ~3844-token filing-extraction request (LON-113):
      `cache_creation_input_tokens: 3844`, then `cache_read_input_tokens: 3844`
      on the second call — caching engaged.
    * Haiku 4.5 with the same prompt shape (LON-113): both cache fields
      came back `0`. Filing-extraction prefix sits above 1024 but below
      4096 tokens — the **Haiku threshold is 2× Sonnet's**, which the
      stale table that used to live here did not call out.

  ### Where caching actually engages today (LON-120)

    * **Complex tier** (Sonnet 4.6 — `s1/s1a/s3/s3a/424b/8-K Item 1.01`
      filings, NewsAnalysis once its prefix grows past 2048): caching
      engages on the 2nd+ call within the ~5-minute window.
    * **Cheap tier** (Haiku 4.5 — `def14a/13d/13g/_8k`): caching does
      **not** engage at current prompt size. The wrapper still attaches
      `cache_control` markers — they no-op below threshold per
      Anthropic's documented behavior. If the cheap-tier prompt grows
      past 4096 tokens in a future ticket, caching engages
      automatically with no code change here.

  This is not a bug or platform limitation — it's a threshold
  mismatch. The cheap-tier choice still earns its keep on base cost
  (Haiku ~$0.80/MTok vs Sonnet ~$3/MTok), which is the actual
  reason that tier exists; caching savings on top would have been a
  bonus, not the design.

  ### No beta header required

  Prompt caching is GA on `anthropic-version: 2023-06-01`. The
  `anthropic-beta: prompt-caching-2024-07-31` header was needed during
  the original beta period and is no longer required for any current
  Claude model.
  """
  @behaviour LongOrShort.AI.Provider

  @path "v1/messages"
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
        base_url: Keyword.fetch!(config, :base_url),
        headers: headers(api_key, config),
        receive_timeout: @receive_timeout,
        retry: false
      )

    case Keyword.get(config, :req_plug) do
      nil -> base
      plug -> Req.merge(base, plug: plug)
    end
  end

  defp headers(api_key, config) do
    [
      {"x-api-key", api_key},
      {"anthropic-version", Keyword.fetch!(config, :anthropic_version)},
      {"content-type", "application/json"}
    ]
  end

  # ─── Request body ─────────────────────────────────────────────────

  defp build_body(messages, tools, opts) do
    config = config()
    {system, chat_messages} = extract_system(messages)

    base = %{
      model: Keyword.get(opts, :model) || Keyword.fetch!(config, :model),
      max_tokens: Keyword.get(opts, :max_tokens) || Keyword.fetch!(config, :max_tokens),
      messages: chat_messages,
      tools: mark_last_cacheable(tools),
      tool_choice: Keyword.get(opts, :tool_choice, %{type: "auto"})
    }

    case system do
      nil -> base
      text -> Map.put(base, :system, system_blocks(text))
    end
  end

  # Wraps the system text in a single content block tagged for ephemeral
  # caching. Anthropic accepts either a plain string or a list of blocks
  # for the `system` parameter; the list shape is required to attach
  # `cache_control`.
  defp system_blocks(text) do
    [%{type: "text", text: text, cache_control: %{type: "ephemeral"}}]
  end

  # Marks the last tool with an ephemeral cache breakpoint. Anthropic's
  # cache prefix extends through the last `cache_control` marker in body
  # order, so this captures the entire `system + tools` block as the
  # cacheable prefix for prompt caching.
  defp mark_last_cacheable([]), do: []

  defp mark_last_cacheable(tools) do
    List.update_at(tools, -1, &Map.put(&1, :cache_control, %{type: "ephemeral"}))
  end

  # Anthropic's Messages API rejects role:"system" inside the messages list —
  # system content goes as a top-level `system` parameter. Other providers
  # (OpenAI) accept system inside messages. Normalizing here keeps the
  # `LongOrShort.AI.Provider.message/0` contract uniform across providers:
  # callers freely pass system messages and we route them correctly.
  defp extract_system(messages) do
    {systems, chat} = Enum.split_with(messages, fn %{role: role} -> role == "system" end)

    system_text =
      case systems do
        [] -> nil
        msgs -> msgs |> Enum.map(& &1.content) |> Enum.join("\n\n")
      end

    {system_text, chat}
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

  defp normalize(%{"content" => content} = body) when is_list(content) do
    usage = extract_usage(body)

    :telemetry.execute(
      [:long_or_short, :ai, :claude, :call],
      usage,
      %{}
    )

    {:ok,
     %{
       tool_calls: extract_tool_calls(content),
       text: extract_text(content),
       usage: usage
     }}
  end

  defp normalize(body), do: {:error, {:invalid_response, body}}

  defp extract_tool_calls(content) do
    for %{"type" => "tool_use", "name" => name, "input" => input} <- content do
      %{name: name, input: input}
    end
  end

  defp extract_text(content) do
    text =
      content
      |> Stream.filter(fn
        %{"type" => "text"} -> true
        _ -> false
      end)
      |> Enum.map_join("", fn %{"text" => t} -> t end)

    if text == "", do: nil, else: text
  end

  # Returns a stable 4-key shape regardless of whether the API emitted
  # cache fields. Callers and the telemetry handler can both rely on
  # the keys being present; missing fields default to 0.
  defp extract_usage(body) do
    usage = Map.get(body, "usage", %{})

    %{
      input_tokens: Map.get(usage, "input_tokens", 0),
      output_tokens: Map.get(usage, "output_tokens", 0),
      cache_creation_input_tokens: Map.get(usage, "cache_creation_input_tokens", 0),
      cache_read_input_tokens: Map.get(usage, "cache_read_input_tokens", 0)
    }
  end

  # Req 0.5 stores headers as %{name => [values]}.
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
    case Application.fetch_env(:long_or_short, :anthropic_api_key) do
      {:ok, key} when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :no_api_key}
    end
  end
end
