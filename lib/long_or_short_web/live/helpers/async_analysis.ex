defmodule LongOrShortWeb.Live.AsyncAnalysis do
  @moduledoc """
  Shared helpers for the async news-analysis flow used by three
  LiveViews (`feed`, `dashboard`, `analyze`).

  * `spawn_analyzer/3` wraps the `Task.Supervisor` start + error
    forwarding so each LiveView doesn't restate it.
  * `format_error/1` turns analyzer error reasons into user-facing
    flash messages.

  Per-view divergence intentionally stays per-view:

    * `handle_info({:news_analysis_ready, _}, _)` and
      `handle_info({:analyze_failed, _, _}, _)` — each view does
      different update work (refresh_card / reload_article_in_lists /
      single-article state), so wrapping them in a macro/callback
      module would add complexity without removing real duplication.
    * The `is_nil(actor.trading_profile)` pre-check — only 2 of 3
      LiveViews have it; the third (`analyze_live`) has a different
      flow shape (no pre-fetched article list).

  Extracted in LON-144 from the 2026-05-12 code duplication audit.
  """

  alias LongOrShort.Analysis.NewsAnalyzer

  @doc """
  Spawns the analyzer in a supervised Task. On success, the analyzer
  broadcasts `{:news_analysis_ready, _}` via PubSub — the calling
  LiveView's `handle_info` picks it up. On failure, sends
  `{:analyze_failed, article_id, reason}` directly to `parent` so the
  LiveView can flash + reset state.
  """
  @spec spawn_analyzer(map(), term(), pid()) :: {:ok, pid()} | {:error, term()}
  def spawn_analyzer(article, actor, parent) do
    Task.Supervisor.start_child(LongOrShort.Analysis.TaskSupervisor, fn ->
      case NewsAnalyzer.analyze(article, actor: actor) do
        {:ok, _analysis} ->
          # Success delivered via PubSub → handle_info({:news_analysis_ready, _}, _)
          :ok

        {:error, reason} ->
          send(parent, {:analyze_failed, article.id, reason})
      end
    end)
  end

  @doc """
  Maps analyzer error reasons to user-facing flash text. Unknown
  reasons fall through to `inspect/1` so dev errors stay visible
  without crashing the LiveView.
  """
  @spec format_error(term()) :: String.t()
  def format_error({:ai_call_failed, _}), do: "AI provider failed — try again."
  def format_error(:no_tool_call), do: "Model returned an unexpected response."
  def format_error({:invalid_enum, field, value}), do: "Bad #{field} value: #{inspect(value)}"
  def format_error(:no_trading_profile), do: "Set up your TradingProfile first."
  def format_error(reason), do: inspect(reason)
end
