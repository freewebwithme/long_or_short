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

  ## Errors

  All errors are returned as `{:error, reason}`. Retries / backoff are
  the caller's responsibility (see `LongOrShort.Analysis.RepetitionAnalyzer`,
  LON-27). Possible reasons:

    * `{:http_error, status, body}` — non-2xx response
    * `{:rate_limited, retry_after}` — 429 (`retry_after` may be nil)
    * `{:network_error, reason}` — transport failure
    * `{:invalid_response, body}` — JSON shape unexpected
    * `:no_api_key` — `:anthropic_api_key` is unset
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

    %{
      model: Keyword.get(opts, :model) || Keyword.fetch!(config, :model),
      max_tokens: Keyword.get(opts, :max_tokens) || Keyword.fetch!(config, :max_tokens),
      messages: messages,
      tools: tools,
      tool_choice: Keyword.get(opts, :tool_choice, %{type: "auto"})
    }
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
    {:ok,
     %{
       tool_calls: extract_tool_calls(content),
       text: extract_text(content),
       usage: extract_usage(body)
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

  defp extract_usage(%{"usage" => %{} = usage}) do
    %{
      input_tokens: usage["input_tokens"],
      output_tokens: usage["output_tokens"]
    }
  end

  defp extract_usage(_), do: %{}

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
