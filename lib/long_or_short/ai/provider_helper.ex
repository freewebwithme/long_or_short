defmodule LongOrShort.AI.ProviderHelper do
  @moduledoc """
  Shared HTTP / response plumbing for `LongOrShort.AI.Provider` impls.

  Provider-agnostic concerns live here:

    * HTTP POST with uniform error shape
    * Req client construction + optional `:req_plug` merge
    * Response status dispatch (200 / 429 / 4xx-5xx)
    * `retry-after` header extraction
    * Standard 4-key `usage` shape

  Provider-specific concerns (message normalization, tool translation,
  body building, cache-control markers) stay in the provider module.

  Extracted in LON-143 after `Claude` and `Qwen` providers grew ~100
  lines of duplicated HTTP boilerplate.
  """

  @default_receive_timeout :timer.seconds(60)

  @doc """
  Builds a `Req` client with the providers' shared defaults
  (`retry: false`, 60s receive timeout). Pass `base_url`, `headers`,
  and optionally `req_plug` (typical in tests).
  """
  @spec new_client(keyword()) :: Req.Request.t()
  def new_client(opts) do
    base =
      Req.new(
        base_url: Keyword.fetch!(opts, :base_url),
        headers: Keyword.fetch!(opts, :headers),
        receive_timeout: Keyword.get(opts, :receive_timeout, @default_receive_timeout),
        retry: false
      )

    case Keyword.get(opts, :req_plug) do
      nil -> base
      plug -> Req.merge(base, plug: plug)
    end
  end

  @doc """
  POST a JSON body to `path` on `client`. Returns
  `{:ok, %Req.Response{}}` on transport success (any HTTP status) or
  `{:error, {:network_error, reason}}` on transport failure.
  """
  @spec post(Req.Request.t(), String.t(), map()) ::
          {:ok, Req.Response.t()} | {:error, {:network_error, term()}}
  def post(client, path, body) do
    case Req.post(client, url: path, json: body) do
      {:ok, %Req.Response{} = response} ->
        {:ok, response}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, {:network_error, reason}}

      {:error, reason} ->
        {:error, {:network_error, reason}}
    end
  end

  @doc """
  Dispatches a `%Req.Response{}` by HTTP status.

    * `200` with a map body → `{:ok, body}` so the provider can normalize.
    * `429` → `{:error, {:rate_limited, retry_after}}`.
    * `400..599` → `{:error, {:http_error, status, body}}`.
    * Anything else (e.g. non-map 200 body) → `{:error, {:invalid_response, body}}`.
  """
  @spec dispatch(Req.Response.t()) :: {:ok, map()} | {:error, term()}
  def dispatch(%Req.Response{status: 200, body: body}) when is_map(body), do: {:ok, body}

  def dispatch(%Req.Response{status: 429, headers: headers}),
    do: {:error, {:rate_limited, retry_after(headers)}}

  def dispatch(%Req.Response{status: status, body: body}) when status in 400..599,
    do: {:error, {:http_error, status, body}}

  def dispatch(%Req.Response{body: body}), do: {:error, {:invalid_response, body}}

  @doc """
  Extracts `retry-after` from a Req 0.5 headers map (`%{name => [values]}`).
  Returns the first value or `nil` if absent.
  """
  @spec retry_after(map() | any()) :: String.t() | nil
  def retry_after(%{} = headers) do
    case Map.get(headers, "retry-after") do
      [value | _] -> value
      _ -> nil
    end
  end

  def retry_after(_), do: nil

  @doc """
  Builds the standard 4-key `usage` shape every provider returns.

  Options:

    * `:input_key` — JSON key for input token count (default `"input_tokens"`).
    * `:output_key` — JSON key for output token count (default `"output_tokens"`).
    * `:include_cache` — when `true`, copy `cache_creation_input_tokens`
      and `cache_read_input_tokens` from the body's usage map; when
      `false` (default), both stay 0. Anthropic emits cache fields;
      OpenAI-compat (Qwen) does not.

  Missing fields default to 0 so callers can rely on the shape.
  """
  @spec usage_map(map(), keyword()) :: %{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          cache_creation_input_tokens: non_neg_integer(),
          cache_read_input_tokens: non_neg_integer()
        }
  def usage_map(body, opts \\ []) do
    usage = Map.get(body, "usage") || %{}
    input_key = Keyword.get(opts, :input_key, "input_tokens")
    output_key = Keyword.get(opts, :output_key, "output_tokens")
    include_cache? = Keyword.get(opts, :include_cache, false)

    %{
      input_tokens: Map.get(usage, input_key, 0),
      output_tokens: Map.get(usage, output_key, 0),
      cache_creation_input_tokens:
        if(include_cache?, do: Map.get(usage, "cache_creation_input_tokens", 0), else: 0),
      cache_read_input_tokens:
        if(include_cache?, do: Map.get(usage, "cache_read_input_tokens", 0), else: 0)
    }
  end
end
