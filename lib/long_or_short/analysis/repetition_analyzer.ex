defmodule LongOrShort.Analysis.RepetitionAnalyzer do
  @moduledoc """
   Single-shot orchestrator for the repetition analysis pipeline.

   ## What this solves

   When breaking news arrives for a ticker, the trader's first question is
   "have I seen this story before?". A fourth partnership announcement
   carries far less weight than the first; pump-and-fade patterns become
   obvious only when prior coverage is in view. Manually, that lookup
   takes a few minutes per ticker — exactly the kind of mechanical work
   an LLM should absorb. This module is the function that turns a single
   Article id into an answer.

   ## Where it sits

       News ingestion (LON-8 sources)
           │  publishes :new_article on PubSub
           ▼
       Analysis worker (LON-28)
           │  fans out per article
           ▼
       RepetitionAnalyzer.analyze/1   ← you are here
           │
           ├── News.get_article/2                  (load article + ticker)
           ├── Analysis.start_repetition_analysis  (:pending row)
           ├── News.list_recent_articles_for_ticker (last 30d, ≤20, ex-self)
           ├── AI.Prompts.RepetitionCheck.build/2  (provider-agnostic prompt)
           ├── AI.Tools.RepetitionCheck.spec/0     (provider-agnostic tool)
           ├── AI.call/3                           (Claude or whatever's
           │                                        configured — Tool Use forced)
           ├── validate/1                          (schema + UUID + enum)
           └── :complete | :fail
                   │
                   └── Analysis.Events             (broadcast on :complete)
                           ▼
                       LiveView feed (LON-29)

   Sub-6 (LON-28) wraps `analyze/1` in a GenServer that subscribes to the
   news topic; this module itself is synchronous and side-effect-bounded
   to the DB + one PubSub message.

   ## Lifecycle: pending → complete | fail

   A `:pending` row is written **before** the LLM call so that:

     * concurrent triggers for the same article don't double-charge the
       API (callers can check for an in-flight pending row),
     * the UI can render a "analyzing…" state immediately,
     * a permanent record exists even if the LLM call crashes mid-flight.

   Outcomes are terminal:

     * `:complete` — input passed validation, attributes saved, PubSub
       `{:repetition_analysis_complete, analysis}` broadcast on
       `LongOrShort.Analysis.Events`.
     * `:failed` — anything else. `error_message` carries a tagged
       reason (`"rate_limited: …"`, `"validation_failed: …"`, etc.) so
       operators can categorize failures from the DB.

   No retry loop here. Rate-limit and transient-error policy belongs to
   the worker layer (LON-28); permanent failures (malformed article,
   schema-violating LLM output) shouldn't be retried at all. Re-running
   the analyzer simply creates a fresh row — the resource allows
   multiple analyses per article so re-runs are safe and auditable.

   ## Authorization

   Internally uses `Accounts.SystemActor` to bypass policies. The
   analyzer is a background service, never reached from user input.
   This will migrate to the `public? false` action pattern once LON-15
   ships.

   ## Public surface

       RepetitionAnalyzer.analyze(article_id)
       #=> {:ok, %RepetitionAnalysis{status: :complete | :failed}}
       #=> {:error, term()}   # only for hard preconditions: missing article,
                             #  failure to create the :pending row, etc.

   Note: a *failed analysis* still returns `{:ok, analysis}` — the row
   with `status: :failed` is the documented outcome. `{:error, _}` is
   reserved for failures *before* a pending row exists.
  """

  alias LongOrShort.{AI, Analysis, News}
  alias LongOrShort.AI.Prompts.RepetitionCheck, as: Prompt
  alias LongOrShort.AI.Tools.RepetitionCheck, as: Tool
  alias LongOrShort.Accounts.SystemActor
  alias LongOrShort.Analysis.Events

  @lookback_days 30
  @max_past_articles 20

  @spec analyze(Ecto.UUID.t()) ::
          {:ok, Analysis.RepetitionAnalysis.t()} | {:error, term()}
  def analyze(article_id) do
    actor = SystemActor.new()

    with {:ok, article} <- News.get_article(article_id, load: [:ticker], actor: actor),
         :ok <- guard_against_in_flight(article_id, actor),
         {:ok, past} <- load_past_articles(article, actor),
         {:ok, analysis} <-
           Analysis.start_repetition_analysis(article_id, actor: actor) do
      Events.broadcast_repetition_analysis_started(analysis)
      run_analysis(article, past, analysis, actor)
    end
  end

  defp guard_against_in_flight(article_id, actor) do
    case Analysis.get_pending_repetition_analysis(article_id, actor: actor) do
      {:ok, nil} -> :ok
      {:ok, %{}} -> {:error, :already_in_progress}
      {:error, _} = err -> err
    end
  end

  defp load_past_articles(article, actor) do
    since = DateTime.add(DateTime.utc_now(), -@lookback_days, :day)

    News.list_recent_articles_for_ticker(
      article.ticker_id,
      since,
      %{limit: @max_past_articles, exclude_id: article.id},
      actor: actor
    )
  end

  defp run_analysis(article, past, analysis, actor) do
    tool = Tool.spec()
    messages = Prompt.build(article, past)

    case AI.call(messages, [tool], tool_choice: %{type: "tool", name: tool.name}) do
      {:ok, %{tool_calls: [%{name: "report_repetition_analysis", input: input} | _]} = resp} ->
        handle_tool_call(input, resp.usage, analysis, actor)

      {:ok, %{tool_calls: []}} ->
        fail(analysis, "invalid_response: no tool call", actor)

      {:error, {:rate_limited, _} = reason} ->
        fail(analysis, "rate_limited: #{inspect(reason)}", actor)

      {:error, {:network_error, _} = reason} ->
        fail(analysis, "network_error: #{inspect(reason)}", actor)

      {:error, {:http_error, _, _} = reason} ->
        fail(analysis, "http_error: #{inspect(reason)}", actor)

      {:error, {:invalid_response, _} = reason} ->
        fail(analysis, "invalid_response: #{inspect(reason)}", actor)

      {:error, reason} ->
        fail(analysis, "unknown: #{inspect(reason)}", actor)
    end
  end

  defp handle_tool_call(input, usage, analysis, actor) do
    case validate(input) do
      {:ok, normalized} ->
        complete(analysis, normalized, usage, actor)

      {:error, reason} ->
        fail(analysis, "validation_failed: #{inspect(reason)}", actor)
    end
  end

  defp complete(analysis, normalized, usage, actor) do
    attrs =
      Map.merge(normalized, %{
        model_used: claude_model(),
        tokens_used_input: Map.get(usage, :input_tokens),
        tokens_used_output: Map.get(usage, :output_tokens)
      })

    case Analysis.complete_repetition_analysis(analysis, attrs, actor: actor) do
      {:ok, completed} ->
        Events.broadcast_repetition_analysis_complete(completed)
        {:ok, completed}

      err ->
        err
    end
  end

  defp fail(analysis, message, actor) do
    case Analysis.fail_repetition_analysis(analysis, %{error_message: message}, actor: actor) do
      {:ok, failed} ->
        Events.broadcast_repetition_analysis_failed(failed)
        {:ok, failed}

      err ->
        err
    end
  end

  defp validate(input) when is_map(input) do
    with {:ok, is_rep} <- fetch(input, "is_repetition", &is_boolean/1),
         {:ok, count} <- fetch(input, "repetition_count", &is_integer/1),
         :ok <- check(count >= 1, {:invalid_repetition_count, count}),
         {:ok, fatigue_str} <- fetch(input, "fatigue_level", &is_binary/1),
         {:ok, fatigue} <- parse_fatigue(fatigue_str),
         {:ok, reasoning} <- fetch(input, "reasoning", &is_binary/1),
         related = Map.get(input, "related_article_ids", []),
         :ok <- validate_uuid_list(related) do
      {:ok,
       %{
         is_repetition: is_rep,
         repetition_count: count,
         fatigue_level: fatigue,
         reasoning: reasoning,
         theme: Map.get(input, "theme"),
         related_article_ids: related
       }}
    end
  end

  defp validate(other), do: {:error, {:not_a_map, other}}

  defp fetch(map, key, guard) do
    case Map.fetch(map, key) do
      {:ok, value} -> if guard.(value), do: {:ok, value}, else: {:error, {:invalid, key}}
      :error -> {:error, {:missing, key}}
    end
  end

  defp check(true, _), do: :ok
  defp check(false, reason), do: {:error, reason}

  defp parse_fatigue("low"), do: {:ok, :low}
  defp parse_fatigue("medium"), do: {:ok, :medium}
  defp parse_fatigue("high"), do: {:ok, :high}
  defp parse_fatigue(other), do: {:error, {:invalid_fatigue, other}}

  defp validate_uuid_list(list) when is_list(list) do
    if Enum.all?(list, &valid_uuid?/1),
      do: :ok,
      else: {:error, :invalid_uuid_in_related_article_ids}
  end

  defp validate_uuid_list(_), do: {:error, :related_article_ids_not_a_list}

  defp valid_uuid?(value) when is_binary(value) do
    match?({:ok, _}, Ecto.UUID.cast(value))
  end

  defp valid_uuid?(_), do: false

  defp claude_model do
    :long_or_short
    |> Application.get_env(LongOrShort.AI.Providers.Claude, [])
    |> Keyword.get(:model, "unknown")
  end
end
