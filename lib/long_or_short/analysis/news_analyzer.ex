defmodule LongOrShort.Analysis.NewsAnalyzer do
  @moduledoc """
  Run a Claude-driven news analysis for one article and persist it as
  a `LongOrShort.Analysis.NewsAnalysis` row.

  This is the brain of the LON-78 epic — it ties together:

    * `LongOrShort.News.Article` (the input)
    * `LongOrShort.Accounts.TradingProfile` (per-user persona, LON-88)
    * `LongOrShort.AI.Tools.NewsAnalysis` (output schema, LON-81)
    * `LongOrShort.AI.Prompts.NewsAnalysis` (system + user messages, LON-81)
    * `LongOrShort.AI.call/3` (provider-agnostic LLM call, LON-23)
    * `LongOrShort.Analysis.NewsAnalysis` (the persisted row, LON-79)

  ## Pipeline

  `analyze/2` is one function call: given an article, run the analysis
  and persist it.

      1. Ensure article.ticker is loaded
      2. Load the actor's TradingProfile
      3. Load prior same-ticker articles (default 14 days, cap 10)
      4. Build messages via Prompts.NewsAnalysis.build/3
      5. Call AI with messages + Tools.NewsAnalysis.spec()
      6. Extract the tool_call, validate enum atoms
      7. Combine tool input + ticker snapshot + Phase 1 stubs +
         provenance into one attrs map
      8. Upsert the NewsAnalysis row (SystemActor for the write)
      9. Broadcast `{:news_analysis_ready, analysis}` on the
         article-scoped topic

  ## Actor handling

  The caller passes their own user struct in `opts[:actor]` — that's
  the trader whose `TradingProfile` shapes the prompt. The persistence
  write uses `SystemActor` internally so trader's read-only policy on
  `NewsAnalysis` doesn't block the analyzer.

  ## Phase 1 stubs

  `:pump_fade_risk` is set to `:insufficient_data` and `:strategy_match`
  to `:partial` — explicitly written, not relying on attribute defaults.
  This is consistent regardless of whether the LLM tries to send those
  fields (the tool schema doesn't expose them, but defense in depth).

  Phase 2 (rule-based `:strategy_match` from price/float/RVOL) and
  Phase 4 (`:pump_fade_risk` from a `price_reactions` history table)
  fill these with real values via separate code paths that update the
  same row.

  ## Errors

    * `{:error, {:ai_call_failed, reason}}` — provider error from `AI.call/3`
    * `{:error, :no_tool_call}` — model returned text instead of invoking the tool
    * `{:error, {:invalid_enum, field, value}}` — model returned a value not in the resource's enum
    * `{:error, :no_trading_profile}` — actor has no `TradingProfile` row (run the seed)
    * any Ash error — passed through from the upsert
  """

  require Logger

  alias LongOrShort.{AI, Accounts, Analysis, News}
  alias LongOrShort.AI.{Prompts, Tools}
  alias LongOrShort.Accounts.SystemActor
  alias LongOrShort.Analysis.{Events, NewsAnalysis}
  alias LongOrShort.News.Article

  @prior_window_days 14
  @prior_limit 10

  # Mirrored from `NewsAnalysis` resource constraints (LON-79). Used to
  # validate atoms coming back from the LLM via `String.to_existing_atom/1`
  # — anything outside these lists fails fast with an :invalid_enum error
  # instead of trying to insert and getting a less helpful Ash error.
  @catalyst_strengths ~w(strong medium weak unknown)a
  @catalyst_types ~w(partnership ma fda earnings offering rfp contract_win
                         guidance clinical regulatory other)a
  @sentiments ~w(positive neutral negative)a
  @verdicts ~w(trade watch skip)a

  @doc """
  Run an analysis for the given article. Returns the persisted (or
  upserted-over-existing) `NewsAnalysis` row, or an error tuple.

  ## Required opts

    * `:actor` — the trader user whose `TradingProfile` drives the
      prompt persona

  ## Optional opts

    * `:prior_window_days` — how far back to look for prior same-ticker
      articles (default 14)
    * `:prior_limit` — cap on prior articles passed to the prompt
      (default 10)
    * `:model` — override the LLM model (passed through to `AI.call/3`)
    * `:provider` — override the configured AI provider (test injection)

  ## Examples

      actor = ... # current_user
      {:ok, article} = News.get_article(id, load: [:ticker], actor: actor)
      {:ok, analysis} = NewsAnalyzer.analyze(article, actor: actor)
  """
  @spec analyze(Article.t(), keyword()) ::
          {:ok, NewsAnalysis.t()} | {:error, term()}
  def analyze(%Article{} = article, opts \\ []) do
    actor = Keyword.fetch!(opts, :actor)
    window = Keyword.get(opts, :prior_window_days, @prior_window_days)
    limit = Keyword.get(opts, :prior_limit, @prior_limit)

    with {:ok, article} <- ensure_ticker_loaded(article),
         {:ok, profile} <- load_profile(actor),
         {:ok, prior} <- load_prior_articles(article, window, limit),
         messages = Prompts.NewsAnalysis.build(article, prior, profile),
         tools = [Tools.NewsAnalysis.spec()],
         {:ok, response} <- call_ai(messages, tools, opts),
         {:ok, tool_input} <- extract_tool_call(response),
         {:ok, attrs} <- build_attrs(article, tool_input, response, opts),
         {:ok, analysis} <- persist(attrs) do
      Events.broadcast_analysis_ready(analysis)
      {:ok, analysis}
    end
  end

  # ── Pipeline steps ─────────────────────────────────────────────────
  defp ensure_ticker_loaded(%Article{ticker: %_{}} = article), do: {:ok, article}

  defp ensure_ticker_loaded(%Article{} = article) do
    News.get_article(article.id, load: [:ticker], actor: SystemActor.new())
  end

  defp load_profile(actor) do
    case Accounts.get_trading_profile_by_user(actor.id, authorize?: false) do
      {:ok, %_{} = profile} -> {:ok, profile}
      {:ok, nil} -> {:error, :no_trading_profile}
      {:error, _} = err -> err
    end
  end

  defp load_prior_articles(article, window_days, limit) do
    cutoff = DateTime.add(DateTime.utc_now(), -window_days * 24 * 3600, :second)

    case News.list_articles_by_ticker(article.ticker_id, actor: SystemActor.new()) do
      {:ok, articles} ->
        prior =
          articles
          |> Enum.filter(fn a ->
            a.id != article.id and DateTime.compare(a.published_at, cutoff) != :lt
          end)
          |> Enum.sort_by(& &1.published_at, {:desc, DateTime})
          |> Enum.take(limit)

        {:ok, prior}

      {:error, _} = err ->
        err
    end
  end

  defp call_ai(messages, tools, opts) do
    case AI.call(messages, tools, opts) do
      {:ok, _} = ok ->
        ok

      {:error, reason} ->
        Logger.warning("[NewsAnalyzer] AI call failed: #{inspect(reason)}")
        {:error, {:ai_call_failed, reason}}
    end
  end

  defp extract_tool_call(%{tool_calls: [%{name: "record_news_analysis", input: input} | _]}),
    do: {:ok, input}

  defp extract_tool_call(response) do
    Logger.warning(
      "[NewsAnalyzer] No record_news_analysis tool call in response: #{inspect(response)}"
    )

    {:error, :no_tool_call}
  end

  defp build_attrs(article, input, response, opts) do
    with {:ok, catalyst_strength} <-
           to_enum_atom(:catalyst_strength, input["catalyst_strength"], @catalyst_strengths),
         {:ok, catalyst_type} <-
           to_enum_atom(:catalyst_type, input["catalyst_type"], @catalyst_types),
         {:ok, sentiment} <- to_enum_atom(:sentiment, input["sentiment"], @sentiments),
         {:ok, verdict} <- to_enum_atom(:verdict, input["verdict"], @verdicts) do
      ticker = article.ticker

      attrs = %{
        article_id: article.id,
        # Card signals (from LLM)
        catalyst_strength: catalyst_strength,
        catalyst_type: catalyst_type,
        sentiment: sentiment,
        repetition_count: input["repetition_count"] || 1,
        repetition_summary: input["repetition_summary"],
        verdict: verdict,
        headline_takeaway: input["headline_takeaway"],
        # Detail view (from LLM)
        detail_summary: input["detail_summary"],
        detail_positives: input["detail_positives"],
        detail_concerns: input["detail_concerns"],
        detail_checklist: input["detail_checklist"],
        detail_recommendation: input["detail_recommendation"],
        # Snapshot at analysis time (from ticker)
        price_at_analysis: ticker.last_price,
        float_shares_at_analysis: ticker.float_shares,
        rvol_at_analysis: nil,
        # Phase 1 stubs (explicit, not relying on attribute defaults)
        pump_fade_risk: :insufficient_data,
        strategy_match: :partial,
        strategy_match_reasons: %{},
        # Provenance
        llm_provider: provenance_provider(),
        llm_model: resolve_model(opts),
        input_tokens: get_in(response, [:usage, :input_tokens]),
        output_tokens: get_in(response, [:usage, :output_tokens])
      }

      {:ok, attrs}
    end
  end

  defp to_enum_atom(field, value, allowed) when is_atom(value) do
    if value in allowed do
      {:ok, value}
    else
      log_invalid_enum(field, value)
      {:error, {:invalid_enum, field, value}}
    end
  end

  defp to_enum_atom(field, value, allowed) when is_binary(value) do
    atom = String.to_existing_atom(value)

    if atom in allowed do
      {:ok, atom}
    else
      log_invalid_enum(field, value)
      {:error, {:invalid_enum, field, value}}
    end
  rescue
    ArgumentError ->
      log_invalid_enum(field, value)
      {:error, {:invalid_enum, field, value}}
  end

  defp to_enum_atom(field, value, _allowed) do
    log_invalid_enum(field, value)
    {:error, {:invalid_enum, field, value}}
  end

  defp log_invalid_enum(field, value) do
    Logger.warning("[NewsAnalyzer] Invalid #{field} value from LLM: #{inspect(value)}")
  end

  defp resolve_model(opts) do
    Keyword.get(opts, :model) ||
      Application.get_env(:long_or_short, LongOrShort.AI.Providers.Claude, [])
      |> Keyword.get(:model, "unknown")
  end

  defp provenance_provider do
    case AI.default_provider() do
      LongOrShort.AI.MockProvider -> :mock
      LongOrShort.AI.Providers.Claude -> :claude
      _ -> :other
    end
  end

  defp persist(attrs) do
    Analysis.upsert_news_analysis(attrs, actor: SystemActor.new())
  end
end
