defmodule LongOrShort.MorningBrief.Generator do
  @moduledoc """
  Generates a Morning Brief for a given time-bucket by calling the
  configured web-search-enabled LLM provider and upserting the result
  into `LongOrShort.Analysis.MorningBriefDigest` (LON-150).

  ## Provider dispatch (LON-148 swap point)

  The provider module is read from app config:

      config :long_or_short, :morning_brief_provider,
        LongOrShort.AI.Providers.Claude   # default — `:anthropic`

  When LON-148 lands, swapping to Qwen native web_search is a single
  config flip plus a new `provider_label/1` clause below. No call-site
  changes anywhere else.

  The provider module must export `call_with_search/2` returning
  `{:ok, %{text, citations, usage, search_calls}}` (the shape
  `Providers.Claude.call_with_search/2` documents).

  ## Timeout

  The hard timeout is the provider HTTP client's `receive_timeout`,
  which defaults to 60 seconds via `LongOrShort.AI.ProviderHelper`.
  No explicit Task wrapping here — if the API hangs past 60s the
  provider returns `{:network_error, :timeout}` and this function
  returns `{:error, _}` so the calling Oban worker (LON-151) can
  apply its own backoff/retry.

  ## Telemetry

    * `[:long_or_short, :morning_brief, :generated]` —
      measurements `%{duration_ms, input_tokens, output_tokens,
      search_calls}`, metadata `%{bucket}`.
    * `[:long_or_short, :morning_brief, :generation_failed]` —
      measurements `%{duration_ms}`, metadata `%{bucket, reason}`.
  """

  alias LongOrShort.Analysis
  alias LongOrShort.Analysis.MorningBriefDigest
  alias LongOrShort.MorningBrief.Prompts
  alias LongOrShortWeb.MorningBrief.Bucket

  @valid_buckets ~w(overnight premarket after_open)a

  @type bucket :: :overnight | :premarket | :after_open

  @default_model "claude-haiku-4-5-20251001"
  @default_max_searches 5

  @doc """
  Generate the brief for `bucket` and upsert the resulting Digest.

  ## Options

    * `:et_now` — override the wall-clock used to compute
      `bucket_date` and the user-prompt timestamp. Tests inject a
      frozen DateTime; production callers omit it.
    * `:model` — LLM model id. Defaults to the `ANTHROPIC_MODEL`
      env var, then to `"claude-haiku-4-5-20251001"`. `ANTHROPIC_MODEL=claude-sonnet-4-6`
      is the LON-149 quality-escape flip.
    * `:max_searches` — server-side cap on `web_search` tool
      invocations (default #{@default_max_searches}).
  """
  @spec generate_for_bucket(bucket(), keyword()) ::
          {:ok, MorningBriefDigest.t()} | {:error, term()}
  def generate_for_bucket(bucket, opts \\ []) when bucket in @valid_buckets do
    et_now = Keyword.get_lazy(opts, :et_now, &Bucket.et_now/0)
    model = Keyword.get_lazy(opts, :model, &resolve_model/0)
    max_searches = Keyword.get(opts, :max_searches, @default_max_searches)
    started_at = System.monotonic_time(:millisecond)

    messages = Prompts.build(bucket, et_now)
    provider = provider_module()
    provider_opts = [model: model, max_uses: max_searches]

    case provider.call_with_search(messages, provider_opts) do
      {:ok, response} ->
        attrs = build_attrs(bucket, et_now, response, provider, model)

        case Analysis.upsert_digest(attrs, authorize?: false) do
          {:ok, digest} ->
            emit_success(bucket, response, started_at)
            {:ok, digest}

          {:error, reason} = err ->
            emit_failure(bucket, {:persist_failed, reason}, started_at)
            err
        end

      {:error, reason} = err ->
        emit_failure(bucket, reason, started_at)
        err
    end
  end

  # ── Provider dispatch (LON-148 swap point) ────────────────────────

  defp provider_module do
    Application.fetch_env!(:long_or_short, :morning_brief_provider)
  end

  # Maps provider module → `MorningBriefDigest.llm_provider` enum
  # value. LON-148 will append a `Providers.QwenNative -> :qwen_native`
  # clause. Test fakes fall through to `:anthropic` so they satisfy
  # the resource enum constraint without polluting the prod enum.
  defp provider_label(LongOrShort.AI.Providers.Claude), do: :anthropic
  defp provider_label(_other), do: :anthropic

  # ── Attribute build ───────────────────────────────────────────────

  defp build_attrs(bucket, et_now, response, provider, model) do
    usage = response[:usage] || %{}

    %{
      bucket_date: DateTime.to_date(et_now),
      bucket: bucket,
      content: response[:text] || "",
      citations: response[:citations] || [],
      llm_provider: provider_label(provider),
      llm_model: model,
      input_tokens: Map.get(usage, :input_tokens, 0),
      output_tokens: Map.get(usage, :output_tokens, 0),
      search_calls: response[:search_calls] || 0,
      raw_response: response_to_jsonb(response)
    }
  end

  # Round-trip through Jason to sanitize atom keys / DateTime / etc.
  # into a jsonb-safe shape. Mirrors `NewsAnalyzer.build_raw_response/2`.
  defp response_to_jsonb(response) do
    response |> Jason.encode!() |> Jason.decode!()
  end

  # ── Telemetry ─────────────────────────────────────────────────────

  defp emit_success(bucket, response, started_at) do
    usage = response[:usage] || %{}
    duration_ms = System.monotonic_time(:millisecond) - started_at

    :telemetry.execute(
      [:long_or_short, :morning_brief, :generated],
      %{
        duration_ms: duration_ms,
        input_tokens: Map.get(usage, :input_tokens, 0),
        output_tokens: Map.get(usage, :output_tokens, 0),
        search_calls: response[:search_calls] || 0
      },
      %{bucket: bucket}
    )
  end

  defp emit_failure(bucket, reason, started_at) do
    duration_ms = System.monotonic_time(:millisecond) - started_at

    :telemetry.execute(
      [:long_or_short, :morning_brief, :generation_failed],
      %{duration_ms: duration_ms},
      %{bucket: bucket, reason: reason}
    )
  end

  # ── Helpers ───────────────────────────────────────────────────────

  defp resolve_model do
    System.get_env("ANTHROPIC_MODEL", @default_model)
  end
end
