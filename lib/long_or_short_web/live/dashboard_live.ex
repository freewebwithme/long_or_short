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
    {:noreply, update(socket, :analyses, &Map.put(&1, id, analysis))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_path={@current_path}>
      <div class="space-y-4">
        <.placeholder_card
          id="dash-search"
          title="Ticker search"
          hint="Search by symbol or company"
        />

        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <.placeholder_card
            id="dash-indices"
            title="Major indices"
            hint="DJIA · NASDAQ-100 · S&P 500"
          />
          <.watchlist_card watchlist={@watchlist} />
        </div>

        <.news_card news={@news} analyses={@analyses} />
      </div>
    </Layouts.app>
    """
  end

  # ── Cards ───────────────────────────────────────────────────────

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

  defp news_card(assigns) do
    ~H"""
    <section id="dash-news" class="card bg-base-200 border border-base-300 p-4">
      <h2 class="font-semibold mb-3">Latest news</h2>

      <div :if={@news == []} class="italic text-xs opacity-60">
        No news yet — waiting for ingest
      </div>

      <div :if={@news != []} class="space-y-2">
        <ArticleComponents.article_card
          :for={article <- @news}
          article={article}
          analysis={Map.get(@analyses, article.id)}
        />
      </div>
    </section>
    """
  end

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
