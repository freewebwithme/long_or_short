defmodule LongOrShortWeb.DashboardLive do
  @moduledoc """
  Dashboard skeleton — landing for authenticated users.

  Composes four widgets: ticker search, indices, condensed news,
  watchlist quick view. Search/indices/news still placeholder cards;
  watchlist is wired to the file-backed watchlist (LON-64) with live
  prices via the shared `PriceLabel` hook (LON-60).
  """
  use LongOrShortWeb, :live_view

  alias LongOrShort.{Analysis, News, Tickers}
  alias LongOrShort.Analysis.{Events, RepetitionAnalyzer}
  alias LongOrShort.Tickers.Watchlist
  alias LongOrShortWeb.Format
  alias LongOrShortWeb.Live.Components.ArticleComponents

  @news_limit 10

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(LongOrShort.PubSub, "prices")
      News.Events.subscribe()
      Events.subscribe()
    end

    actor = socket.assigns.current_user
    news = load_news(actor)
    analyses = load_latest_analyses(news, actor)

    socket =
      socket
      |> assign(:watchlist, load_watchlist(actor))
      |> assign(:news, news)
      |> assign(:analyses, analyses)
      |> assign(:active_news, [])
      |> assign(:active_analyses, %{})
      |> assign(:search_query, "")
      |> assign(:search_results, [])
      |> assign(:active_ticker, nil)

    {:ok, socket}
  end

  @impl true
  def handle_event("analyze", %{"id" => article_id}, socket) do
    Task.Supervisor.start_child(
      LongOrShort.Analysis.TaskSupervisor,
      fn -> RepetitionAnalyzer.analyze(article_id) end
    )

    {:noreply, socket}
  end

  def handle_event("search", %{"query" => query}, socket) do
    query = String.trim(query)
    actor = socket.assigns.current_user

    results =
      case query do
        "" ->
          []

        query ->
          case Tickers.search_tickers(query, actor: actor) do
            {:ok, list} ->
              list

            _ ->
              []
          end
      end

    {:noreply,
     socket
     |> assign(:search_query, query)
     |> assign(:search_results, results)}
  end

  def handle_event("select_ticker", %{"symbol" => symbol}, socket) do
    actor = socket.assigns.current_user

    with {:ok, ticker} <- Tickers.get_ticker_by_symbol(symbol, actor: actor),
         {:ok, articles} <-
           News.list_articles_by_ticker_symbol(symbol, load: [:ticker], actor: actor) do
      {:noreply,
       socket
       |> assign(:active_ticker, ticker)
       |> assign(:active_news, articles)
       |> assign(:search_query, ticker.symbol)
       |> assign(:search_results, [])
       |> assign(:active_analyses, load_latest_analyses(articles, actor))}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("clear_search", _params, socket) do
    {:noreply,
     socket
     |> assign(:search_query, "")
     |> assign(:search_results, [])
     |> assign(:active_ticker, nil)
     |> assign(:active_news, [])
     |> assign(:active_analyses, %{})}
  end

  @impl true
  def handle_info({:price_tick, symbol, price}, socket) do
    {:noreply, push_event(socket, "price_tick", %{symbol: symbol, price: Format.price(price)})}
  end

  def handle_info({:new_article, article}, socket) do
    case News.get_article(article.id,
           load: [:ticker],
           actor: socket.assigns.current_user
         ) do
      {:ok, article} ->
        news =
          [article | socket.assigns.news]
          |> Enum.take(@news_limit)

        {:noreply, assign(socket, :news, news)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_info({event, %{article_id: id} = analysis}, socket)
      when event in [
             :repetition_analysis_started,
             :repetition_analysis_complete,
             :repetition_analysis_failed
           ] do
    active_ids = socket.assigns.active_news |> Enum.map(& &1.id) |> MapSet.new()

    socket =
      update(socket, :analyses, &Map.put(&1, id, analysis))

    socket =
      if MapSet.member?(active_ids, id) do
        update(socket, :active_analyses, &Map.put(&1, id, analysis))
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_path={@current_path}>
      <div class="space-y-4" phx-window-keydown="clear_search" phx-key="Escape">
        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <.placeholder_card
            id="dash-indices"
            title="Major indices"
            hint="DJIA · NASDAQ-100 · S&P 500"
          />
          <.watchlist_card watchlist={@watchlist} />
        </div>
        
    <!-- Middle: search + ticker info/news -->
        <div class="grid grid-cols-1 md:grid-cols-[320px_1fr] gap-4">
          <.search_card query={@search_query} results={@search_results} />
          <div class="space-y-4">
            <.ticker_info_card active_ticker={@active_ticker} />
            <.ticker_news_card
              active_ticker={@active_ticker}
              news={@active_news}
              analyses={@active_analyses}
            />
          </div>
        </div>
        <!-- Bottom: global latest news -->
        <.global_news_card news={@news} analyses={@analyses} />
      </div>
    </Layouts.app>
    """
  end

  # ── Cards ───────────────────────────────────────────────────────
  attr :active_ticker, :any, required: true

  defp ticker_info_card(assigns) do
    ~H"""
    <section id="dash-info" class="card bg-base-200 border border-base-300 p-4">
      <h2 class="font-semibold mb-3">Ticker info</h2>

      <div :if={!@active_ticker} class="italic text-xs opacity-60">
        Search and select a ticker to see details
      </div>

      <div :if={@active_ticker} class="space-y-2">
        <div class="flex items-baseline gap-2">
          <span class="font-bold text-lg">{@active_ticker.symbol}</span>
          <span :if={@active_ticker.company_name} class="text-sm opacity-70 truncate">
            {@active_ticker.company_name}
          </span>
        </div>

        <dl class="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-xs">
          <dt class="opacity-60">Last price</dt>
          <dd class="tabular-nums">
            <ArticleComponents.price_label
              id={"info-price-#{@active_ticker.symbol}"}
              symbol={@active_ticker.symbol}
              initial_price={@active_ticker.last_price}
              class="tabular-nums"
            />
          </dd>

          <dt class="opacity-60">Exchange</dt>
          <dd>{@active_ticker.exchange || "—"}</dd>

          <dt class="opacity-60">Industry</dt>
          <dd>{@active_ticker.industry || "—"}</dd>

          <dt class="opacity-60">Float</dt>
          <dd class="tabular-nums">{Format.shares(@active_ticker.float_shares)}</dd>

          <dt class="opacity-60">Shares out</dt>
          <dd class="tabular-nums">{Format.shares(@active_ticker.shares_outstanding)}</dd>
        </dl>
      </div>
    </section>
    """
  end

  attr :active_ticker, :any, required: true
  attr :news, :list, required: true
  attr :analyses, :map, required: true

  defp ticker_news_card(assigns) do
    ~H"""
    <section id="dash-news" class="card bg-base-200 border border-base-300 p-4">
      <h2 class="font-semibold mb-3">
        {if @active_ticker, do: "#{@active_ticker.symbol} news", else: "Latest news"}
      </h2>

      <div :if={@news == []} class="italic text-xs opacity-60">
        No news yet
      </div>

      <div :if={@news != []} class="space-y-2">
        <ArticleComponents.article_card
          :for={article <- @news}
          article={article}
          analysis={Map.get(@analyses, article.id)}
          context="active"
        />
      </div>
    </section>
    """
  end

  defp search_card(assigns) do
    ~H"""
    <section id="dash-search" class="card bg-base-200 border border-base-300 p-4">
      <h2 class="font-semibold mb-3">Ticker search</h2>

      <form phx-change="search" phx-submit="search" autocomplete="off">
        <div class="relative">
          <input
            type="text"
            name="query"
            value={@query}
            placeholder="Symbol or company"
            phx-debounce="200"
            class="input input-sm input-bordered w-full pr-8"
          />
          <button
            :if={@query != ""}
            type="button"
            phx-click="clear_search"
            class="absolute right-1 top-1 btn btn-ghost btn-xs btn-circle"
            aria-label="Clear search"
          >
            <.icon name="hero-x-mark" class="size-3" />
          </button>
        </div>
      </form>

      <ul :if={@results != []} class="mt-2 divide-y divide-base-300 text-sm">
        <li :for={ticker <- @results}>
          <button
            type="button"
            phx-click="select_ticker"
            phx-value-symbol={ticker.symbol}
            class="w-full text-left p-2 hover:bg-base-300 rounded"
          >
            <div class="font-bold">{ticker.symbol}</div>
            <div :if={ticker.company_name} class="text-xs opacity-60 truncate">
              {ticker.company_name}
            </div>
          </button>
        </li>
      </ul>

      <div :if={@query != "" && @results == []} class="text-xs opacity-60 mt-2 italic">
        No matches
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :hint, :string, default: ""

  defp placeholder_card(assigns) do
    ~H"""
    <section id={@id} class="card bg-base-200 border border-base-300 p-6">
      <h2 class="font-semibold">{@title}</h2>
      <p :if={@hint != ""} class="text-sm opacity-60 mt-1">{@hint}</p>
      <div class="mt-4 italic text-xs opacity-40">Coming soon</div>
    </section>
    """
  end

  attr :watchlist, :list, required: true

  defp watchlist_card(assigns) do
    ~H"""
    <section id="dash-watchlist" class="card bg-base-200 border border-base-300 p-4">
      <h2 class="font-semibold mb-3">Watchlist</h2>

      <div :if={@watchlist == []} class="italic text-xs opacity-60">
        Add symbols to <code>priv/watchlist.txt</code>
      </div>

      <ul
        :if={@watchlist != []}
        class="grid grid-cols-2 sm:grid-cols-3 gap-x-6 gap-y-1.5 text-sm"
      >
        <li :for={item <- @watchlist} class="flex items-center justify-between">
          <.link navigate={~p"/feed"} class="font-bold hover:underline">{item.symbol}</.link>
          <ArticleComponents.price_label
            id={"watchlist-price-#{item.symbol}"}
            symbol={item.symbol}
            initial_price={item.last_price}
            class="opacity-60 tabular-nums"
          />
        </li>
      </ul>
    </section>
    """
  end

  attr :news, :list, required: true
  attr :analyses, :map, required: true

  defp global_news_card(assigns) do
    ~H"""
    <section id="dash-global-news" class="card bg-base-200 border border-base-300 p-4">
      <h2 class="font-semibold mb-3">Latest news</h2>

      <div :if={@news == []} class="italic text-xs opacity-60">
        No news yet
      </div>

      <div :if={@news != []} class="space-y-2">
        <ArticleComponents.article_card
          :for={article <- @news}
          article={article}
          analysis={Map.get(@analyses, article.id)}
          context="global"
        />
      </div>
    </section>
    """
  end

  #
  # ── helpers ─────────────────────────────────────────────────────

  defp load_watchlist(actor) do
    Enum.map(Watchlist.symbols(), fn symbol ->
      case Tickers.get_ticker_by_symbol(symbol, actor: actor) do
        {:ok, ticker} -> %{symbol: symbol, last_price: ticker.last_price}
        _ -> %{symbol: symbol, last_price: nil}
      end
    end)
  end

  defp load_news(actor) do
    case News.list_recent_articles(%{limit: @news_limit}, load: [:ticker], actor: actor) do
      {:ok, articles} -> articles
      _ -> []
    end
  end

  defp load_latest_analyses(articles, actor) do
    articles
    |> Enum.map(& &1.id)
    |> Enum.reduce(%{}, fn article_id, acc ->
      case Analysis.get_latest_repetition_analysis(article_id, actor: actor) do
        {:ok, %{} = analysis} -> Map.put(acc, article_id, analysis)
        _ -> acc
      end
    end)
  end
end
