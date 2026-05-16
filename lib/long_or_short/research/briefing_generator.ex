defmodule LongOrShort.Research.BriefingGenerator do
  @moduledoc """
  Sync entry point for the on-demand Pre-Trade Briefing (LON-172, PT-1).

  Mirrors `LongOrShort.MorningBrief.Generator` (LON-151) but
  on-demand instead of cron, persona-injected per requesting user,
  and routed through the `:research_briefing_provider` config key.

  ## Pipeline

  1. Resolve `symbol` → `Tickers.Ticker` via the existing symbol
     index. Unknown symbol → `{:error, :unknown_symbol}` (no LLM call).
  2. Load the requesting user's `TradingProfile`. No profile →
     `{:error, :no_trading_profile}` — refuse to brief without a
     persona to inject.
  3. Cache check via `Research.get_latest_briefing_for/2`. That read
     already filters `cached_until > now()`, so a non-nil result is a
     guaranteed fresh hit; we return it without an LLM call (DB cache
     HIT path).
  4. Cache MISS: gather context (`get_dilution_profile/1`, recent
     `NewsAnalysis` rows for this ticker, last 7 days, capped).
  5. Build messages via `Research.Prompts.TickerBriefing.build/3`.
  6. `Provider.call_with_search/2` on the configured provider.
  7. Compute `cached_until` and snapshot the trader profile.
  8. Upsert the `TickerBriefing` row (as `SystemActor`).
  9. Emit `[:long_or_short, :ticker_briefing, :generated | :generation_failed]`
     telemetry — same shape as Morning Brief's events so dashboard
     filters carry over.
  10. Return `{:ok, briefing}` or `{:error, reason}`.

  ## Provider dispatch

  Provider module read from `:research_briefing_provider` app env
  (defaults to `LongOrShort.AI.Providers.Claude`). Independent from
  the Morning Brief provider so each surface can flip separately
  when LON-148-style Qwen fallback rolls out.

  ## Caching policy (PT-1 placeholder)

  PT-1 uses a flat 10-minute TTL for any cache hit. The time-bucketed
  policy (premarket=5min, regular=10min, after-hours=15min,
  overnight=60min, weekend=4h) lives in PT-3 ([[LON-174]]).
  `cached_until` already gets written; PT-3 just changes the function
  that computes it.

  ## Why Sonnet by default (not Haiku like Morning Brief)

  Briefing is decision-grade single-ticker analysis with persona
  injection and dilution context — the value-density per call
  justifies the higher-quality model. Morning Brief defaults to
  Haiku because it's broad market commentary where breadth beats
  per-sentence precision. Both are env-overridable.
  """

  require Logger

  alias LongOrShort.Accounts.SystemActor
  alias LongOrShort.Analysis
  alias LongOrShort.Research
  alias LongOrShort.Research.Prompts.TickerBriefing, as: BriefingPrompts
  alias LongOrShort.Research.TickerBriefing
  alias LongOrShort.Tickers

  # Default model is read from app config so the trader can flip
  # Sonnet ↔ Haiku without a code change. See `resolve_model/0`.
  @fallback_model "claude-sonnet-4-6"

  # LON-179 cost-tuning defaults. The 5-search default was empirically
  # blowing input context past 30K tokens (web_search results stack on
  # every turn); 3 is the empirical sweet spot for decision-grade
  # briefings. `@default_max_output_tokens` caps the 7-section output —
  # Sonnet was hitting ~2,650 tokens on NVDA, 2,048 forces tighter
  # synthesis without truncating utility. `@default_receive_timeout_ms`
  # gives Anthropic's internal `web_search` chain the wall-clock it
  # legitimately needs (3-search Sonnet round-trip is 30-90s).
  @default_max_searches 3
  @default_max_output_tokens 2048
  @default_receive_timeout_ms 180_000

  # PT-1 placeholder; PT-3 (LON-174) replaces with the time-of-day table.
  @default_ttl_minutes 10
  @recent_analyses_days 7
  @recent_analyses_limit 10

  @type generate_opts :: [
          model: String.t(),
          max_searches: pos_integer(),
          max_tokens: pos_integer(),
          receive_timeout: pos_integer(),
          et_now: DateTime.t()
        ]

  @doc """
  Generate a briefing for `symbol` on behalf of `user`.

  Returns `{:ok, %TickerBriefing{}}` whether the row came from cache
  or a fresh LLM call — the caller doesn't have to care. Use the
  `:generated_at` timestamp to tell them apart.

  ## Options

    * `:model` — provider model id. Defaults to
      `Application.get_env(:long_or_short, :research_briefing_model)`,
      falling back to `#{inspect(@fallback_model)}`. Flip to a Haiku
      model id via dev/prod config to trade quality for cost.
    * `:max_searches` — server-side `web_search` cap (default
      #{@default_max_searches}).
    * `:max_tokens` — output cap (default #{@default_max_output_tokens}).
    * `:receive_timeout` — HTTP receive timeout in ms
      (default #{@default_receive_timeout_ms}).
    * `:et_now` — wall-clock override for tests (production omits).
  """
  @spec generate(String.t(), Accounts.User.t(), generate_opts()) ::
          {:ok, TickerBriefing.t()} | {:error, term()}
  def generate(symbol, user, opts \\ []) when is_binary(symbol) do
    upcased = String.upcase(symbol)

    with {:ok, ticker} <- resolve_ticker(upcased),
         {:ok, profile} <- resolve_profile(user),
         {:ok, :miss} <- check_cache(upcased, user.id) do
      generate_fresh(ticker, user, profile, opts)
    else
      {:ok, %TickerBriefing{} = cached} ->
        {:ok, cached}

      {:error, _reason} = err ->
        err
    end
  end

  # ── Cache lookup ────────────────────────────────────────────────

  defp resolve_ticker(symbol) do
    case Tickers.get_ticker_by_symbol(symbol, authorize?: false) do
      {:ok, ticker} -> {:ok, ticker}
      _ -> {:error, :unknown_symbol}
    end
  end

  defp resolve_profile(%{trading_profile: %Ash.NotLoaded{}}),
    do: {:error, :trading_profile_not_loaded}

  defp resolve_profile(%{trading_profile: nil}), do: {:error, :no_trading_profile}
  defp resolve_profile(%{trading_profile: profile}), do: {:ok, profile}
  defp resolve_profile(_), do: {:error, :no_trading_profile}

  defp check_cache(symbol, user_id) do
    case Research.get_latest_briefing_for(symbol, user_id, authorize?: false) do
      {:ok, nil} -> {:ok, :miss}
      {:ok, %TickerBriefing{} = cached} -> {:ok, cached}
      {:error, _} = err -> err
    end
  end

  # ── Fresh generation ────────────────────────────────────────────

  defp generate_fresh(ticker, user, profile, opts) do
    started_at = System.monotonic_time(:millisecond)
    et_now = Keyword.get_lazy(opts, :et_now, fn -> DateTime.utc_now() end)
    model = Keyword.get_lazy(opts, :model, &resolve_model/0)
    max_searches = Keyword.get(opts, :max_searches, @default_max_searches)
    max_tokens = Keyword.get(opts, :max_tokens, @default_max_output_tokens)
    receive_timeout = Keyword.get(opts, :receive_timeout, @default_receive_timeout_ms)

    context = build_context(ticker, user, et_now)
    messages = BriefingPrompts.build(ticker, profile, context)

    provider = provider_module()

    provider_opts = [
      model: model,
      max_uses: max_searches,
      max_tokens: max_tokens,
      receive_timeout: receive_timeout
    ]

    case provider.call_with_search(messages, provider_opts) do
      {:ok, response} ->
        persist_and_broadcast(ticker, user, profile, response, model, provider, et_now, started_at)

      {:error, reason} = err ->
        emit_failure(ticker.id, reason, started_at)
        err
    end
  end

  defp build_context(ticker, user, _et_now) do
    %{
      dilution_profile: load_dilution_profile(ticker),
      recent_news_analyses: load_recent_analyses(ticker.id, user.id)
    }
  end

  defp load_dilution_profile(ticker) do
    # `Tickers.get_dilution_profile/1` takes a ticker_id (UUID) and
    # returns the profile directly (no tuple wrap). It may raise
    # underneath if the underlying Ash query fails — graceful fallback
    # to nil so the briefing still generates with the "internal data
    # missing" prompt branch.
    Tickers.get_dilution_profile(ticker.id)
  rescue
    _ -> nil
  end

  defp load_recent_analyses(ticker_id, _user_id) do
    since = DateTime.add(DateTime.utc_now(), -@recent_analyses_days * 24 * 3600, :second)

    case Analysis.list_recent_analyses(authorize?: false) do
      {:ok, items} ->
        items
        |> Enum.filter(fn a ->
          a.article && a.article.ticker_id == ticker_id and
            DateTime.compare(a.analyzed_at, since) != :lt
        end)
        |> Enum.take(@recent_analyses_limit)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp persist_and_broadcast(ticker, user, profile, response, model, provider, et_now, started_at) do
    attrs = build_attrs(ticker, user, profile, response, model, provider, et_now)

    case Research.upsert_ticker_briefing(attrs, actor: SystemActor.new()) do
      {:ok, briefing} ->
        emit_success(ticker.id, model, response, started_at)
        {:ok, briefing}

      {:error, reason} ->
        emit_failure(ticker.id, {:persist_failed, reason}, started_at)
        {:error, reason}
    end
  end

  # ── Attribute build ─────────────────────────────────────────────

  defp build_attrs(ticker, user, profile, response, model, provider, et_now) do
    usage = response[:usage] || %{}

    %{
      symbol: ticker.symbol,
      narrative: response[:text] || "",
      structured: %{},
      citations: response[:citations] || [],
      provider: provider_label(provider),
      model: model,
      usage: jsonb(usage),
      cached_until: DateTime.add(et_now, @default_ttl_minutes * 60, :second),
      trading_profile_snapshot: profile_snapshot(profile),
      ticker_id: ticker.id,
      generated_for_user_id: user.id
    }
  end

  defp profile_snapshot(profile) do
    Map.take(profile, [
      :trading_style,
      :time_horizon,
      :market_cap_focuses,
      :catalyst_preferences,
      :price_min,
      :price_max,
      :float_max,
      :notes
    ])
    |> jsonb()
  end

  # Round-trip through Jason so atom keys / Decimal / DateTime all
  # become jsonb-safe scalars. Same trick as MorningBrief.Generator.
  defp jsonb(map), do: map |> Jason.encode!() |> Jason.decode!()

  defp provider_label(LongOrShort.AI.Providers.Claude), do: :anthropic
  defp provider_label(LongOrShort.AI.MockProvider), do: :mock
  defp provider_label(_other), do: :anthropic

  defp provider_module do
    Application.fetch_env!(:long_or_short, :research_briefing_provider)
  end

  # Reads the configured Scout model with a literal fallback so an
  # unconfigured env doesn't crash. Mirrors `MorningBrief.Generator`'s
  # `resolve_model/0`. Flip dev/prod config to `"claude-haiku-4-5-20251001"`
  # to test the Haiku quality trade-off (LON-179).
  defp resolve_model do
    Application.get_env(:long_or_short, :research_briefing_model, @fallback_model)
  end

  # ── Telemetry ───────────────────────────────────────────────────

  defp emit_success(ticker_id, model, response, started_at) do
    usage = response[:usage] || %{}
    duration_ms = System.monotonic_time(:millisecond) - started_at

    :telemetry.execute(
      [:long_or_short, :ticker_briefing, :generated],
      %{
        duration_ms: duration_ms,
        input_tokens: Map.get(usage, :input_tokens, 0),
        output_tokens: Map.get(usage, :output_tokens, 0),
        cache_creation_input_tokens: Map.get(usage, :cache_creation_input_tokens, 0),
        cache_read_input_tokens: Map.get(usage, :cache_read_input_tokens, 0),
        search_calls: response[:search_calls] || 0
      },
      %{ticker_id: ticker_id, model: model}
    )
  end

  defp emit_failure(ticker_id, reason, started_at) do
    duration_ms = System.monotonic_time(:millisecond) - started_at

    :telemetry.execute(
      [:long_or_short, :ticker_briefing, :generation_failed],
      %{duration_ms: duration_ms},
      %{ticker_id: ticker_id, reason: inspect(reason)}
    )
  end
end
