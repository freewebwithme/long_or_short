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

  alias LongOrShort.AI.ProviderHelper

  @path "v1/messages"

  @impl true
  def call(messages, tools, opts \\ []) do
    with {:ok, key} <- api_key(),
         body = build_body(messages, tools, opts),
         {:ok, response} <- ProviderHelper.post(client(key), @path, body),
         {:ok, response_body} <- ProviderHelper.dispatch(response) do
      normalize(response_body)
    end
  end

  @doc """
  Call the Messages API with Anthropic's built-in `web_search` tool
  enabled, returning a citation-preserving response shape.

  Unlike `call/3`, this entry point is web-search-specific and is **not**
  part of the `LongOrShort.AI.Provider` behaviour. Used by the Morning
  Brief generator (LON-151), which needs URLs/titles of every source the
  model consulted — information the standard `call/3` normalizer drops.

  ## Opts
    * `:model` — overrides the configured default. Pass
      `"claude-haiku-4-5-20251001"` for the Morning Brief Phase 1 default
      (cost-tuned), or `"claude-sonnet-4-6"` for the LON-149 escape.
    * `:max_tokens` — output cap (default from config)
    * `:max_uses` — server-side cap on `web_search` invocations per turn.
      Anthropic enforces this; we default to 5. Reducing this is the
      primary lever for keeping per-brief input-token usage in check.

  ## Returns

      {:ok, %{
        text: String.t() | nil,                # concatenated narrative
        citations: [%{idx, url, title, source, cited_text, accessed_at}],
        usage: %{...},                         # standard usage + :web_search_requests
        search_calls: non_neg_integer()        # convenience copy
      }}

  Errors mirror `call/3`'s shape — see module doc.
  """
  @spec call_with_search([map()], keyword()) :: {:ok, map()} | {:error, term()}
  def call_with_search(messages, opts \\ []) do
    with {:ok, key} <- api_key(),
         body = build_search_body(messages, opts),
         {:ok, response} <- ProviderHelper.post(client(key, opts), @path, body),
         {:ok, response_body} <- ProviderHelper.dispatch(response) do
      normalize_search(response_body)
    end
  end

  # ─── HTTP ──────────────────────────────────────────────────────────

  # `opts[:receive_timeout]` is threaded into the underlying `Req` client
  # so per-call callers (Scout briefing → 180s, Morning Brief → default
  # 60s) can opt for longer HTTP waits. `ProviderHelper.new_client/1`
  # falls back to its 60s default when the key is absent. See LON-179
  # for the timeout root cause analysis.
  defp client(api_key, opts \\ []) do
    config = config()

    client_opts = [
      base_url: Keyword.fetch!(config, :base_url),
      headers: headers(api_key, config),
      req_plug: Keyword.get(config, :req_plug)
    ]

    case Keyword.get(opts, :receive_timeout) do
      nil -> ProviderHelper.new_client(client_opts)
      t -> ProviderHelper.new_client(Keyword.put(client_opts, :receive_timeout, t))
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

  defp normalize(%{"content" => content} = body) when is_list(content) do
    usage = ProviderHelper.usage_map(body, include_cache: true)

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

  # ─── Config helpers ────────────────────────────────────────────────

  defp config, do: Application.get_env(:long_or_short, __MODULE__, [])

  defp api_key do
    case Application.fetch_env(:long_or_short, :anthropic_api_key) do
      {:ok, key} when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :no_api_key}
    end
  end

  # ─── Web search variant (LON-150) ─────────────────────────────────
  #
  # Web search uses a server-side tool that takes a different request
  # shape than function tools — `%{type: "web_search_20250305", ...}`
  # rather than `%{name, description, input_schema}`. It also returns a
  # richer content stream (interleaved `text` / `server_tool_use` /
  # `web_search_tool_result` blocks) with citations embedded inside
  # `text` blocks. Keeping this path separate avoids contaminating the
  # `call/3` flow that NewsAnalysis depends on.

  defp build_search_body(messages, opts) do
    config = config()
    {system, chat_messages} = extract_system(messages)

    base = %{
      model: Keyword.get(opts, :model) || Keyword.fetch!(config, :model),
      max_tokens: Keyword.get(opts, :max_tokens) || Keyword.fetch!(config, :max_tokens),
      messages: chat_messages,
      tools: [web_search_tool(opts)]
    }

    case system do
      nil -> base
      text -> Map.put(base, :system, system_blocks(text))
    end
  end

  # Server tools may not accept `cache_control`, so we deliberately skip
  # `mark_last_cacheable/1` here. The system block still carries an
  # ephemeral cache marker via `system_blocks/1`, but cron schedules sit
  # > 5min apart so practical hit rate is low anyway.
  #
  # The tool type is version-dated by Anthropic — see
  # `:web_search_tool_version` in `config/config.exs` to bump when a
  # newer revision ships.
  defp web_search_tool(opts) do
    %{
      type: Keyword.fetch!(config(), :web_search_tool_version),
      name: "web_search",
      max_uses: Keyword.get(opts, :max_uses, 5)
    }
  end

  defp normalize_search(%{"content" => content} = body) when is_list(content) do
    text = extract_search_text(content)
    citations = extract_citations(content)
    base_usage = ProviderHelper.usage_map(body, include_cache: true)
    search_calls = get_in(body, ["usage", "server_tool_use", "web_search_requests"]) || 0
    usage = Map.put(base_usage, :web_search_requests, search_calls)

    :telemetry.execute(
      [:long_or_short, :ai, :claude, :call_with_search],
      Map.put(usage, :search_calls, search_calls),
      %{}
    )

    {:ok,
     %{
       text: text,
       citations: citations,
       usage: usage,
       search_calls: search_calls
     }}
  end

  defp normalize_search(body), do: {:error, {:invalid_response, body}}

  # Narrative is the concatenation of every `text` block in order. The
  # `server_tool_use` and `web_search_tool_result` blocks contribute no
  # reader-facing prose — drop them. `[1] [2]` markers added by the model
  # remain inline as it wrote them.
  defp extract_search_text(content) do
    text =
      content
      |> Stream.filter(&match?(%{"type" => "text"}, &1))
      |> Enum.map_join("", & &1["text"])

    if text == "", do: nil, else: text
  end

  # Flatten the per-text-block citations into a deduped, sequentially
  # indexed list. Each raw entry is a `web_search_result_location` with
  # `url / title / cited_text / encrypted_index`; we keep the trader-
  # facing fields, derive a compact `source` from the host, and discard
  # `encrypted_index` (Anthropic-internal pointer).
  defp extract_citations(content) do
    now = DateTime.utc_now()

    {entries, _seen} =
      content
      |> Stream.filter(&match?(%{"type" => "text"}, &1))
      |> Stream.flat_map(fn block -> List.wrap(block["citations"]) end)
      |> Enum.reduce({[], MapSet.new()}, fn raw, {acc, seen} ->
        url = raw["url"]

        cond do
          is_nil(url) ->
            {acc, seen}

          MapSet.member?(seen, url) ->
            {acc, seen}

          true ->
            entry = %{
              url: url,
              title: raw["title"],
              source: derive_source(url),
              cited_text: raw["cited_text"],
              accessed_at: now
            }

            {[entry | acc], MapSet.put(seen, url)}
        end
      end)

    entries
    |> Enum.reverse()
    |> Enum.with_index(1)
    |> Enum.map(fn {entry, idx} -> Map.put(entry, :idx, idx) end)
  end

  defp derive_source(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) ->
        host |> String.replace_prefix("www.", "")

      _ ->
        nil
    end
  end
end
