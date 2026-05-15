defmodule LongOrShort.AI do
  @moduledoc """
  Facade for LLM provider calls.

  Callers route every LLM call through `LongOrShort.AI.call/3`, never
  through a specific provider module. This keeps the rest of the
  codebase free of provider-specific knowledge — swapping Claude for
  another model is a config change, not a code change.

  ## Configuration

      config :long_or_short, :ai_provider, LongOrShort.AI.Providers.Claude

  ## Usage

      LongOrShort.AI.call(messages, tools, model: "claude-sonnet-4-20250514")

  Pass `:provider` in opts to override the configured default (useful
  for tests or A/B comparisons):

      LongOrShort.AI.call(messages, tools, provider: MyMockProvider)

  ## Rate-limit retry (default on)

  Provider responses of `{:error, {:rate_limited, retry_after}}` (HTTP
  429) trigger an automatic retry-with-backoff. The first retry honors
  the provider's `retry-after` header (in seconds); subsequent retries
  fall back to linear backoff. Up to **2 retries** (3 total attempts)
  before the error bubbles up.

  Opt out via `retry: false` — useful for tests that want to assert
  the raw provider error without sleeping.

  Why at the facade: rate-limit recovery is a transport concern that
  every caller (filing extraction, news analysis, future) benefits
  from. Keeping it here means new callers never have to reinvent the
  retry loop. Observed first under LON-135's Tier 1 rollout, where
  20-filing batches against Anthropic Tier 1 / 2 limits caused ~35%
  of Sonnet calls to be silently persisted as `:rejected`.
  """

  require Logger

  @type messages :: [LongOrShort.AI.Provider.message()]
  @type tools :: [LongOrShort.AI.Provider.tool_spec()]
  @type opts :: keyword()

  @max_retries 2
  @default_backoff_ms 1_000

  @doc """
  Send messages + tools to the configured (or overridden) LLM provider.

  Returns the provider's normalized `t:LongOrShort.AI.Provider.response/0`.

  ## Options

    * `:provider` — override the configured `:ai_provider` (tests / A-B).
    * `:retry` — `true` (default) to retry on `{:rate_limited, _}`,
      `false` to surface the error immediately.
    * Anything else is passed through to the provider unchanged.
  """
  @spec call(messages(), tools(), opts()) :: LongOrShort.AI.Provider.response()
  def call(messages, tools, opts \\ []) do
    {retry?, opts} = Keyword.pop(opts, :retry, true)
    {provider, opts} = Keyword.pop(opts, :provider, default_provider())

    if retry? do
      call_with_retry(provider, messages, tools, opts, 0)
    else
      provider.call(messages, tools, opts)
    end
  end

  def default_provider, do: Application.fetch_env!(:long_or_short, :ai_provider)

  defp call_with_retry(provider, messages, tools, opts, attempt) do
    case provider.call(messages, tools, opts) do
      {:error, {:rate_limited, retry_after}} when attempt < @max_retries ->
        wait_ms = compute_wait_ms(retry_after, attempt)

        Logger.warning(
          "[AI] rate-limited — sleeping #{wait_ms}ms before retry " <>
            "#{attempt + 1}/#{@max_retries} (retry_after=#{inspect(retry_after)})"
        )

        Process.sleep(wait_ms)
        call_with_retry(provider, messages, tools, opts, attempt + 1)

      other ->
        other
    end
  end

  # Anthropic returns `retry-after` in seconds (string). If missing or
  # unparseable, fall back to linear backoff scaled by attempt number.
  # Jitter keeps multiple concurrent callers from thundering-herding
  # the same wake-up.
  defp compute_wait_ms(retry_after, attempt) do
    base_ms =
      case Integer.parse(to_string(retry_after || "")) do
        {seconds, _} when seconds > 0 -> seconds * 1_000
        _ -> @default_backoff_ms * (attempt + 1)
      end

    base_ms + :rand.uniform(500)
  end
end
