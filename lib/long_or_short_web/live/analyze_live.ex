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

  alias LongOrShort.{Analysis, News, Tickers}
  alias LongOrShort.Analysis.Events
  alias LongOrShortWeb.Live.DilutionProfiles
  alias LongOrShortWeb.Live.Components.{ArticleComponents, NewsComponents, TickerAutocomplete}

  @recent_page_limit 20

  # ── Mount ─────────────────────────────────────────────────────────────

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: DilutionProfiles.subscribe()

    socket =
      socket
      |> assign(:ticker_query, "")
      |> assign(:ticker_results, [])
      |> assign(:article, nil)
      |> assign(:analyzing?, false)
      |> assign(:expanded?, true)
      |> assign(:form_errors, %{})
      |> assign(:recent_filter_query, "")
      |> assign(:recent_filter_results, [])
      |> assign(:recent_filter_ticker_id, nil)
      |> assign(:dilution_profile, nil)
      |> load_recent_analyses(%{})

    {:ok, socket}
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
         |> assign(:analyzing?, analyzing?)
         |> assign(:dilution_profile, DilutionProfiles.load_one(article.ticker_id))}

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
     |> assign(:form_errors, %{})
     |> assign(:dilution_profile, nil)}
  end

  # ── Events ────────────────────────────────────────────────────────────

  @impl true
  def handle_event("ticker_search", %{"query" => query}, socket) do
    {trimmed, results} =
      LongOrShortWeb.Live.TickerSearchHelper.search(query, socket.assigns.current_user)

    {:noreply,
     socket
     |> assign(:ticker_query, trimmed)
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
      is_nil(actor.trading_profile) ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Set up your trader profile at /profile before running analysis."
         )}

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
            LongOrShortWeb.Live.AsyncAnalysis.spawn_analyzer(article, actor, self())

            {:noreply,
             socket
             |> assign(:form_errors, %{})
             |> push_patch(to: ~p"/analyze/#{article.id}")}

          {:error, reason} ->
            {:noreply,
             put_flash(socket, :error, "Could not save article: #{LongOrShortWeb.Live.AsyncAnalysis.format_error(reason)}")}
        end
    end
  end

  def handle_event("re_analyze", _params, socket) do
    article = socket.assigns.article
    actor = socket.assigns.current_user

    if is_nil(actor.trading_profile) do
      {:noreply,
       put_flash(
         socket,
         :error,
         "Set up your trader profile at /profile before running analysis."
       )}
    else
      LongOrShortWeb.Live.AsyncAnalysis.spawn_analyzer(article, actor, self())
      {:noreply, assign(socket, :analyzing?, true)}
    end
  end

  def handle_event("toggle_detail", _params, socket) do
    {:noreply, update(socket, :expanded?, &(!&1))}
  end

  def handle_event("new_analysis", _params, socket) do
    {:noreply, push_navigate(socket, to: ~p"/analyze")}
  end

  # ── History filter + pagination (LON-108) ─────────────────────────────

  def handle_event("recent_filter_search", %{"query" => query}, socket) do
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
     |> assign(:recent_filter_query, query)
     |> assign(:recent_filter_results, results)}
  end

  def handle_event("recent_filter_select", %{"symbol" => symbol}, socket) do
    actor = socket.assigns.current_user

    case Tickers.get_ticker_by_symbol(symbol, actor: actor) do
      {:ok, ticker} ->
        {:noreply,
         socket
         |> assign(:recent_filter_query, ticker.symbol)
         |> assign(:recent_filter_results, [])
         |> assign(:recent_filter_ticker_id, ticker.id)
         |> load_recent_analyses(%{ticker_id: ticker.id})}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("recent_filter_clear", _params, socket) do
    {:noreply,
     socket
     |> assign(:recent_filter_query, "")
     |> assign(:recent_filter_results, [])
     |> assign(:recent_filter_ticker_id, nil)
     |> load_recent_analyses(%{})}
  end

  def handle_event("load_more_recent", _params, socket) do
    actor = socket.assigns.current_user
    args = filter_args(socket)

    case Analysis.list_recent_analyses(args,
           actor: actor,
           page: [limit: @recent_page_limit, after: socket.assigns.recent_cursor]
         ) do
      {:ok, %Ash.Page.Keyset{results: analyses, more?: more}} ->
        socket =
          analyses
          |> Enum.reduce(socket, fn analysis, sock ->
            stream_insert(sock, :recent_analyses, analysis, at: -1)
          end)
          |> assign(:recent_cursor, last_keyset(analyses) || socket.assigns.recent_cursor)
          |> assign(:recent_more?, more)
          |> update(:recent_count, &(&1 + length(analyses)))

        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  # ── Info ──────────────────────────────────────────────────────────────

  @impl true
  def handle_info({:news_analysis_ready, _analysis}, socket) do
    article = socket.assigns.article

    case News.get_article(article.id,
           load: [:ticker, :news_analysis],
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
     |> put_flash(:error, "Analysis failed: #{LongOrShortWeb.Live.AsyncAnalysis.format_error(reason)}")}
  end

  # Tier 2 promotion (LON-136). Refresh the displayed article's profile
  # only if the broadcast matches its ticker.
  def handle_info({:new_filing_analysis, %{ticker_id: ticker_id}}, socket) do
    case socket.assigns.article do
      %{ticker_id: ^ticker_id} ->
        {:noreply, assign(socket, :dilution_profile, DilutionProfiles.load_one(ticker_id))}

      _ ->
        {:noreply, socket}
    end
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
      <div class={[
        "mx-auto p-6",
        if(@live_action == :new, do: "max-w-7xl", else: "max-w-4xl")
      ]}>
        <%= if @live_action == :new do %>
          <div class="mb-6">
            <h1 class="text-2xl font-bold">Analyze a news article</h1>
            <p class="text-sm opacity-60 mt-1">
              Paste news from Benzinga, pick a ticker, hit Analyze.
            </p>
          </div>

          <div
            :if={is_nil(@current_user.trading_profile)}
            id="analyze-profile-gate"
            class="alert alert-warning mb-4"
          >
            <span>
              You need a trader profile before the analyzer can personalize results.
              <.link navigate={~p"/profile"} class="link link-hover font-semibold">
                Set up your profile →
              </.link>
            </span>
          </div>

          <div class="grid grid-cols-1 lg:grid-cols-5 gap-6 items-start">
            <div class="lg:col-span-3">
              <div class="card bg-base-200 border border-base-300 p-6">
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
                      <option
                        :for={{label, val} <- [{"Benzinga", "benzinga"}, {"Other", "other"}]}
                        value={val}
                      >
                        {label}
                      </option>
                    </select>
                  </div>

                  <div class="mb-6">
                    <label class="text-sm font-medium block mb-1">Paste the article</label>
                    <textarea
                      name="paste"
                      rows="12"
                      placeholder="Paste headline + body here (first line becomes the title)"
                      class="textarea textarea-bordered w-full text-sm font-mono"
                    ></textarea>
                    <p :if={@form_errors[:paste]} class="text-error text-xs mt-1">
                      Article text is required.
                    </p>
                  </div>

                  <div class="flex justify-end">
                    <button
                      type="submit"
                      class="btn btn-primary btn-sm gap-2"
                      disabled={is_nil(@current_user.trading_profile)}
                    >
                      <.icon name="hero-play" class="size-4" /> Analyze
                    </button>
                  </div>
                </form>
              </div>
            </div>

            <section class="lg:col-span-2">
              <h2 class="text-lg font-semibold mb-3">Recent analyses</h2>

              <div class="mb-3">
                <TickerAutocomplete.ticker_autocomplete
                  query={@recent_filter_query}
                  results={@recent_filter_results}
                  search_event="recent_filter_search"
                  select_event="recent_filter_select"
                  clear_event="recent_filter_clear"
                />
              </div>

              <div
                :if={@recent_count == 0}
                class="px-3 py-6 text-center text-sm opacity-60 italic border border-base-300 rounded"
              >
                No analyses yet. Run one to start your history.
              </div>

              <div
                id="recent-analyses"
                phx-update="stream"
                class={[
                  "divide-y divide-base-300 border border-base-300 rounded",
                  @recent_count == 0 && "hidden"
                ]}
              >
                <div :for={{dom_id, analysis} <- @streams.recent_analyses} id={dom_id}>
                  <.link
                    navigate={~p"/analyze/#{analysis.article.id}"}
                    class="block px-3 py-2 hover:bg-base-200 transition"
                  >
                    <div class="flex items-center gap-2 text-sm">
                      <span class="font-bold w-12 shrink-0">
                        {analysis.article.ticker.symbol}
                      </span>
                      <span class="text-xs opacity-50 shrink-0 tabular-nums whitespace-nowrap">
                        {Calendar.strftime(analysis.analyzed_at, "%m/%d")}
                      </span>
                      <span class="flex-1 truncate min-w-0">{analysis.article.title}</span>
                      <NewsComponents.news_pill
                        emoji="🚦"
                        value={analysis.verdict}
                        field={:verdict}
                      />
                    </div>
                  </.link>
                </div>
              </div>

              <div :if={@recent_more?} class="flex justify-center mt-3">
                <button
                  type="button"
                  phx-click="load_more_recent"
                  class="btn btn-outline btn-sm"
                >
                  Load more
                </button>
              </div>
            </section>
          </div>
        <% else %>
          <div class="flex items-center justify-between mb-4">
            <button phx-click="new_analysis" class="btn btn-ghost btn-sm gap-1">
              <.icon name="hero-arrow-left" class="size-4" /> New analysis
            </button>
            <button
              phx-click="re_analyze"
              class="btn btn-outline btn-sm gap-1"
              disabled={is_nil(@current_user.trading_profile)}
            >
              <.icon name="hero-arrow-path" class="size-4" /> Re-analyze
            </button>
          </div>

          <ArticleComponents.article_card
            :if={@article}
            article={@article}
            analysis={extract_analysis(@article)}
            analyzing?={@analyzing?}
            analyze_disabled?={is_nil(@current_user.trading_profile)}
            expanded?={@expanded?}
            dilution_profile={@dilution_profile}
          />
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  # ── Private ───────────────────────────────────────────────────────────

  defp extract_analysis(%{news_analysis: %LongOrShort.Analysis.NewsAnalysis{} = a}), do: a
  defp extract_analysis(_), do: nil

  defp parse_source("other"), do: :other
  defp parse_source(_), do: :benzinga


  # ── History helpers (LON-108) ─────────────────────────────────────────

  defp load_recent_analyses(socket, filter_args) do
    actor = socket.assigns.current_user

    case Analysis.list_recent_analyses(filter_args,
           actor: actor,
           page: [limit: @recent_page_limit]
         ) do
      {:ok, %Ash.Page.Keyset{results: analyses, more?: more}} ->
        socket
        |> assign(:recent_count, length(analyses))
        |> assign(:recent_cursor, last_keyset(analyses))
        |> assign(:recent_more?, more)
        |> stream(:recent_analyses, analyses, reset: true)

      _ ->
        socket
        |> assign(:recent_count, 0)
        |> assign(:recent_cursor, nil)
        |> assign(:recent_more?, false)
        |> stream(:recent_analyses, [], reset: true)
    end
  end

  defp filter_args(socket) do
    case socket.assigns.recent_filter_ticker_id do
      nil -> %{}
      id -> %{ticker_id: id}
    end
  end

  defp last_keyset([]), do: nil

  defp last_keyset(items) do
    case List.last(items) do
      %{__metadata__: %{keyset: cursor}} -> cursor
      _ -> nil
    end
  end
end
