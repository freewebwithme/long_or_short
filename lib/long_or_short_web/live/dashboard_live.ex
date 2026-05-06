defmodule LongOrShortWeb.DashboardLive do
  @moduledoc """
  Dashboard skeleton — landing for authenticated users.

  Composes four widgets: ticker search, indices, condensed news,
  watchlist quick view. Search/indices/news still placeholder cards;
  watchlist quick view reads from the file-backed ingestion universe
  (`LongOrShort.Tickers.Tracked` / LON-64) with live prices via the
  shared `PriceLabel` hook (LON-60). LON-94 will rewire this to the
  per-user DB watchlist.
  """
  use LongOrShortWeb, :live_view

  alias LongOrShort.{Indices, News, Tickers}
  alias LongOrShort.Analysis.Events
  alias LongOrShort.Tickers.Tracked
  alias LongOrShortWeb.Format
  alias LongOrShortWeb.Live.Components.ArticleComponents
  alias LongOrShortWeb.Live.Components.TickerAutocomplete

  @news_limit 10

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(LongOrShort.PubSub, "prices")
      News.Events.subscribe()
      Events.subscribe()
      Indices.Events.subscribe()
    end

    actor = socket.assigns.current_user
    news = load_news(actor)

    socket =
      socket
      |> assign(:watchlist, load_watchlist(actor))
      |> assign(:news, news)
      |> assign(:active_news, [])
      |> assign(:search_query, "")
      |> assign(:search_results, [])
      |> assign(:active_ticker, nil)
      |> assign(:indices, %{})

    {:ok, socket}
  end

  @impl true
  def handle_event("analyze", %{"id" => _article_id}, socket) do
    # LON-83 will rebuild this on top of LON-82's `NewsAnalyzer`.
    socket = put_flash(socket, :info, "Analyzer rebuild in progress — try again soon.")
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
       |> assign(:search_results, [])}
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
     |> assign(:active_news, [])}
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

  def handle_info({:index_tick, label, payload}, socket) do
    {:noreply, update(socket, :indices, &Map.put(&1, label, payload))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_path={@current_path}>
      <div class="space-y-4" phx-window-keydown="clear_search" phx-key="Escape">
        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <.indices_card indices={@indices} />
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
            />
          </div>
        </div>
        <!-- Bottom: global latest news -->
        <.global_news_card news={@news} />
      </div>
    </Layouts.app>
    """
  end

  # ── Cards ───────────────────────────────────────────────────────
  attr :indices, :map, required: true

  defp indices_card(assigns) do
    ~H"""
    <section id="dash-indices" class="card bg-base-200 border border-base-300 p-4">
      <h2 class="font-semibold mb-3">Major indices</h2>
      <div class="grid grid-cols-3 gap-4 text-center">
        <.index_tile
          :for={label <- ["DJIA", "NASDAQ-100", "S&P 500"]}
          label={label}
          data={Map.get(@indices, label)}
        />
      </div>
    </section>
    """
  end

  attr :label, :string, required: true
  attr :data, :any, default: nil

  defp index_tile(assigns) do
    ~H"""
    <div title={index_tooltip(@data)}>
      <div class="text-xs font-semibold opacity-60">{@label}</div>
      <div :if={@data} class={["text-lg font-bold tabular-nums", index_color(@data.change_pct)]}>
        {index_arrow(@data.change_pct)}{Format.pct(@data.change_pct)}
      </div>
      <div :if={!@data} class="text-sm opacity-30 mt-1">—</div>
    </div>
    """
  end

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
      <TickerAutocomplete.ticker_autocomplete query={@query} results={@results} />
    </section>
    """
  end

  attr :watchlist, :list, required: true

  defp watchlist_card(assigns) do
    ~H"""
    <section id="dash-watchlist" class="card bg-base-200 border border-base-300 p-4">
      <h2 class="font-semibold mb-3">Watchlist</h2>

      <div :if={@watchlist == []} class="italic text-xs opacity-60">
        Add symbols to <code>priv/tracked_tickers.txt</code>
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
          context="global"
        />
      </div>
    </section>
    """
  end

  #
  # ── helpers ─────────────────────────────────────────────────────

  defp load_watchlist(actor) do
    Enum.map(Tracked.symbols(), fn symbol ->
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

  defp index_color(pct) do
    cond do
      Decimal.compare(pct, Decimal.new("0.01")) == :gt -> "text-success"
      Decimal.compare(pct, Decimal.new("-0.01")) == :lt -> "text-error"
      true -> "opacity-60"
    end
  end

  defp index_arrow(pct) do
    cond do
      Decimal.compare(pct, Decimal.new("0.01")) == :gt -> "↑ "
      Decimal.compare(pct, Decimal.new("-0.01")) == :lt -> "↓ "
      true -> ""
    end
  end

  defp index_tooltip(nil), do: ""

  defp index_tooltip(%{symbol: sym, current: cur, prev_close: pc, fetched_at: at}) do
    diff = DateTime.diff(DateTime.utc_now(), at, :second)
    age = if diff < 60, do: "#{diff}s ago", else: "#{div(diff, 60)}m ago"
    "#{sym} · $#{cur} · prev close $#{pc} · updated #{age}"
  end
end
