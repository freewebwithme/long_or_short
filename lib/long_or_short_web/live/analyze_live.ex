defmodule LongOrShortWeb.AnalyzeLive do
  @moduledoc """
  /analyze — paste-driven news analysis page (LON-85).

  Two live_actions:

    * `:new`  — empty form. Trader picks ticker, pastes article, clicks Analyze.
    * `:show` — result view at `/analyze/:article_id`. Shows the same
                 MomentumCard used on /feed. Detail view is open by default.

  Flow:
    1. Trader submits form → Article.:create_manual → Article persisted
    2. Task.Supervisor spawns NewsAnalyzer.analyze/2 asynchronously
    3. Analyzer broadcasts {:news_analysis_ready, %NewsAnalysis{}} via PubSub
    4. handle_info reloads the article and renders the card

  Re-analyze: re-spawns the analyzer on the same article (NewsAnalyzer upserts
  the NewsAnalysis row, so no duplicate is created).
  """

  use LongOrShortWeb, :live_view

  alias LongOrShort.{News, Tickers}
  alias LongOrShort.Analysis.{Events, NewsAnalyzer}
  alias LongOrShortWeb.Live.Components.{ArticleComponents, TickerAutocomplete}

  # ── Mount ─────────────────────────────────────────────────────────────

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:ticker_query, "")
     |> assign(:ticker_results, [])
     |> assign(:article, nil)
     |> assign(:analyzing?, false)
     |> assign(:expanded?, true)
     |> assign(:form_errors, %{})}
  end

  # ── Params ────────────────────────────────────────────────────────────

  @impl true
  def handle_params(%{"article_id" => article_id}, _uri, socket) do
    actor = socket.assigns.current_user

    case News.get_article(article_id, load: [:ticker, :news_analysis], actor: actor) do
      {:ok, article} ->
        if connected?(socket), do: Events.subscribe_for_article(article_id)
        analyzing? = is_nil(extract_analysis(article))

        {:noreply,
         socket
         |> assign(:article, article)
         |> assign(:analyzing?, analyzing?)}

      {:error, _} ->
        {:noreply,
         socket
         |> put_flash(:error, "Article not found.")
         |> push_navigate(to: ~p"/analyze")}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:article, nil)
     |> assign(:analyzing?, false)
     |> assign(:expanded?, true)
     |> assign(:form_errors, %{})}
  end

  # ── Events ────────────────────────────────────────────────────────────

  @impl true
  def handle_event("ticker_search", %{"query" => query}, socket) do
    query = String.trim(query)
    actor = socket.assigns.current_user

    results =
      case query do
        "" ->
          []

        q ->
          case Tickers.search_tickers(q, actor: actor) do
            {:ok, list} -> list
            _ -> []
          end
      end

    {:noreply,
     socket
     |> assign(:ticker_query, query)
     |> assign(:ticker_results, results)}
  end

  def handle_event("ticker_selected", %{"symbol" => symbol}, socket) do
    {:noreply,
     socket
     |> assign(:ticker_query, symbol)
     |> assign(:ticker_results, [])}
  end

  def handle_event("ticker_clear", _params, socket) do
    {:noreply,
     socket
     |> assign(:ticker_query, "")
     |> assign(:ticker_results, [])}
  end

  def handle_event("analyze", params, socket) do
    symbol = String.trim(Map.get(params, "symbol", ""))
    paste = String.trim(Map.get(params, "paste", ""))
    source = parse_source(Map.get(params, "source", "benzinga"))
    actor = socket.assigns.current_user

    cond do
      symbol == "" ->
        {:noreply, assign(socket, :form_errors, %{symbol: "required"})}

      paste == "" ->
        {:noreply, assign(socket, :form_errors, %{paste: "required"})}

      true ->
        {title, summary} = split_paste(paste)

        attrs = %{
          source: source,
          symbol: symbol,
          title: title,
          summary: summary,
          url: nil,
          raw_category: nil,
          published_at: DateTime.utc_now()
        }

        case News.create_manual_article(attrs, actor: actor) do
          {:ok, article} ->
            # Subscribe before spawning to avoid a race where the broadcast
            # arrives before handle_params sets up the subscription.
            if connected?(socket), do: Events.subscribe_for_article(article.id)
            spawn_analyzer(article, actor, self())

            {:noreply,
             socket
             |> assign(:form_errors, %{})
             |> push_patch(to: ~p"/analyze/#{article.id}")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Could not save article: #{format_error(reason)}")}
        end
    end
  end

  def handle_event("re_analyze", _params, socket) do
    article = socket.assigns.article
    actor = socket.assigns.current_user
    spawn_analyzer(article, actor, self())
    {:noreply, assign(socket, :analyzing?, true)}
  end

  def handle_event("toggle_detail", _params, socket) do
    {:noreply, update(socket, :expanded?, &(!&1))}
  end

  def handle_event("new_analysis", _params, socket) do
    {:noreply, push_navigate(socket, to: ~p"/analyze")}
  end

  # ── Info ──────────────────────────────────────────────────────────────

  @impl true
  def handle_info({:news_analysis_ready, _analysis}, socket) do
    article = socket.assigns.article

    case News.get_article(article.id, load: [:ticker, :news_analysis],
           actor: socket.assigns.current_user
         ) do
      {:ok, refreshed} ->
        {:noreply,
         socket
         |> assign(:article, refreshed)
         |> assign(:analyzing?, false)}

      {:error, _} ->
        {:noreply, assign(socket, :analyzing?, false)}
    end
  end

  def handle_info({:analyze_failed, _article_id, reason}, socket) do
    {:noreply,
     socket
     |> assign(:analyzing?, false)
     |> put_flash(:error, "Analysis failed: #{format_error(reason)}")}
  end

  # ── Public helpers ────────────────────────────────────────────────────

  @doc """
  Split a raw paste into `{title, summary}`.

  The first line (trimmed, capped at 200 chars) becomes the title; all
  remaining content becomes the summary. Returns `{title, nil}` when
  the paste is a single line.

  Public so it can be unit-tested without mounting the LiveView.
  """
  def split_paste(paste) when is_binary(paste) do
    paste
    |> String.trim()
    |> String.split("\n", parts: 2)
    |> case do
      [title] ->
        {String.slice(String.trim(title), 0, 200), nil}

      [title, body] ->
        {String.slice(String.trim(title), 0, 200), String.trim(body)}
    end
  end

  # ── Render ────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_path={@current_path}>
      <div class="max-w-4xl mx-auto p-6">
        <%= if @live_action == :new do %>
          <div class="mb-6">
            <h1 class="text-2xl font-bold">Analyze a news article</h1>
            <p class="text-sm opacity-60 mt-1">
              Paste news from Benzinga, pick a ticker, hit Analyze.
            </p>
          </div>

          <div class="card bg-base-200 border border-base-300 p-6 max-w-2xl">
            <form id="analyze-form" phx-submit="analyze">
              <div class="mb-4">
                <label class="text-sm font-medium block mb-1">Ticker</label>
                <TickerAutocomplete.ticker_autocomplete
                  query={@ticker_query}
                  results={@ticker_results}
                  search_event="ticker_search"
                  select_event="ticker_selected"
                  clear_event="ticker_clear"
                  wrap_in_form={false}
                />
                <input type="hidden" name="symbol" value={@ticker_query} />
                <p :if={@form_errors[:symbol]} class="text-error text-xs mt-1">
                  Ticker is required.
                </p>
              </div>

              <div class="mb-4">
                <label class="text-sm font-medium block mb-1">Source</label>
                <select name="source" class="select select-sm select-bordered">
                  <option :for={{label, val} <- [{"Benzinga", "benzinga"}, {"Other", "other"}]}
                    value={val}>
                    {label}
                  </option>
                </select>
              </div>

              <div class="mb-6">
                <label class="text-sm font-medium block mb-1">Paste the article</label>
                <textarea
                  name="paste"
                  rows="10"
                  placeholder="Paste headline + body here (first line becomes the title)"
                  class="textarea textarea-bordered w-full text-sm font-mono"
                ></textarea>
                <p :if={@form_errors[:paste]} class="text-error text-xs mt-1">
                  Article text is required.
                </p>
              </div>

              <div class="flex justify-end">
                <button type="submit" class="btn btn-primary btn-sm gap-2">
                  <.icon name="hero-play" class="size-4" /> Analyze
                </button>
              </div>
            </form>
          </div>
        <% else %>
          <div class="flex items-center justify-between mb-4">
            <button phx-click="new_analysis" class="btn btn-ghost btn-sm gap-1">
              <.icon name="hero-arrow-left" class="size-4" /> New analysis
            </button>
            <button phx-click="re_analyze" class="btn btn-outline btn-sm gap-1">
              <.icon name="hero-arrow-path" class="size-4" /> Re-analyze
            </button>
          </div>

          <ArticleComponents.article_card
            :if={@article}
            article={@article}
            analysis={extract_analysis(@article)}
            analyzing?={@analyzing?}
            expanded?={@expanded?}
          />
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  # ── Private ───────────────────────────────────────────────────────────

  defp spawn_analyzer(article, actor, parent) do
    Task.Supervisor.start_child(LongOrShort.Analysis.TaskSupervisor, fn ->
      case NewsAnalyzer.analyze(article, actor: actor) do
        {:ok, _analysis} -> :ok
        {:error, reason} -> send(parent, {:analyze_failed, article.id, reason})
      end
    end)
  end

  defp extract_analysis(%{news_analysis: %LongOrShort.Analysis.NewsAnalysis{} = a}), do: a
  defp extract_analysis(_), do: nil

  defp parse_source("other"), do: :other
  defp parse_source(_), do: :benzinga

  defp format_error({:ai_call_failed, _}), do: "AI provider failed — try again."
  defp format_error(:no_tool_call), do: "Model returned an unexpected response."
  defp format_error({:invalid_enum, field, value}), do: "Bad #{field} value: #{inspect(value)}"
  defp format_error(:no_trading_profile), do: "Set up your TradingProfile first."
  defp format_error(reason), do: inspect(reason)
end
