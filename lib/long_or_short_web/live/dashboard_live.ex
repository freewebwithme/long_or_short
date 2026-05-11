defmodule LongOrShortWeb.DashboardLive do
  @moduledoc """
  Dashboard skeleton — landing for authenticated users.

  Composes four primary widgets: ticker search, indices, watchlist
  quick view, and split news widgets. The watchlist reads from the
  per-user DB-backed `Tickers.WatchlistItem` resource (LON-92). The
  news area shows two cards: "All news" (global ingestion universe)
  and "My watchlist news" (filtered to the trader's tickers).

  ## Subscriptions

    * `"prices"` — live last_price ticks fan out to the PriceLabel hook
    * `News.Events` — newly-ingested articles
    * `Indices.Events` — index ticks (DJIA / NASDAQ-100 / S&P 500)
    * `WatchlistEvents.subscribe(user_id)` — `:watchlist_changed`
      refreshes the watchlist + watchlist news without a manual reload
    * `Analysis.Events.subscribe_for_article/1` — once per article in
      either news widget; delivers `{:news_analysis_ready, _}` after
      the analyzer finishes. Mirrors the FeedLive pattern.

  ## Analyze flow (inline)

  Click on the dashboard's Analyze button spawns the analyzer in place
  and updates the same condensed card when the analysis lands. No
  navigation — keeps the trader's scanning context intact.
  """
  use LongOrShortWeb, :live_view

  alias LongOrShort.{Analysis, Indices, News, Tickers}
  alias LongOrShort.Analysis.NewsAnalyzer
  alias LongOrShort.Tickers.WatchlistEvents
  alias LongOrShortWeb.Format
  alias LongOrShortWeb.Live.Components.ArticleComponents
  alias LongOrShortWeb.Live.Components.TickerAutocomplete
  alias LongOrShortWeb.MorningBrief.Bucket

  @news_limit 10

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user

    if connected?(socket) do
      Phoenix.PubSub.subscribe(LongOrShort.PubSub, "prices")
      News.Events.subscribe()
      Indices.Events.subscribe()
      WatchlistEvents.subscribe(actor.id)
    end

    watchlist = load_watchlist(actor)
    ticker_ids = watchlist_ticker_id_set(watchlist)
    news = load_news(actor)
    watchlist_news = load_watchlist_news(ticker_ids, actor)
    morning_brief_preview = load_morning_brief_preview(actor)

    if connected?(socket) do
      subscribe_for_articles(news ++ watchlist_news)
    end

    socket =
      socket
      |> assign(:watchlist, watchlist)
      |> assign(:watchlist_ticker_ids, ticker_ids)
      |> assign(:news, news)
      |> assign(:watchlist_news, watchlist_news)
      |> assign(:morning_brief_preview, morning_brief_preview)
      |> assign(:analyzing_ids, MapSet.new())
      |> assign(:expanded_ids, MapSet.new())
      |> assign(:active_news, [])
      |> assign(:search_query, "")
      |> assign(:search_results, [])
      |> assign(:active_ticker, nil)
      |> assign(:indices, %{})

    {:ok, socket}
  end

  @impl true
  def handle_event("analyze", %{"id" => article_id}, socket) do
    actor = socket.assigns.current_user

    if is_nil(actor.trading_profile) do
      # Server-side guard — UI gate (LON-102) makes this normally unreachable,
      # but multi-tab or scripted clients could still send the event.
      {:noreply,
       put_flash(
         socket,
         :error,
         "Set up your trader profile at /profile before running analysis."
       )}
    else
      case News.get_article(article_id, load: [:ticker, :news_analysis], actor: actor) do
        {:ok, article} ->
          spawn_analyzer(article, actor, self())

          socket =
            socket
            |> update(:analyzing_ids, &MapSet.put(&1, article_id))
            |> replace_article_in_lists(article)

          {:noreply, socket}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Article not found.")}
      end
    end
  end

  def handle_event("toggle_detail", %{"id" => article_id}, socket) do
    expanded_ids =
      if MapSet.member?(socket.assigns.expanded_ids, article_id) do
        MapSet.delete(socket.assigns.expanded_ids, article_id)
      else
        MapSet.put(socket.assigns.expanded_ids, article_id)
      end

    {:noreply, assign(socket, :expanded_ids, expanded_ids)}
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
           load: [:ticker, :news_analysis],
           actor: socket.assigns.current_user
         ) do
      {:ok, article} ->
        Analysis.Events.subscribe_for_article(article.id)

        news =
          [article | socket.assigns.news]
          |> sort_by_published()
          |> Enum.take(@news_limit)

        watchlist_news =
          if MapSet.member?(socket.assigns.watchlist_ticker_ids, article.ticker_id) do
            [article | socket.assigns.watchlist_news]
            |> sort_by_published()
            |> Enum.take(@news_limit)
          else
            socket.assigns.watchlist_news
          end

        morning_brief_preview =
          [article | socket.assigns.morning_brief_preview]
          |> sort_by_published()
          |> Enum.take(@news_limit)

        {:noreply,
         socket
         |> assign(:news, news)
         |> assign(:watchlist_news, watchlist_news)
         |> assign(:morning_brief_preview, morning_brief_preview)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_info({:news_analysis_ready, %{article_id: article_id}}, socket) do
    {:noreply,
     socket
     |> update(:analyzing_ids, &MapSet.delete(&1, article_id))
     |> reload_article_in_lists(article_id)}
  end

  def handle_info({:analyze_failed, article_id, reason}, socket) do
    {:noreply,
     socket
     |> update(:analyzing_ids, &MapSet.delete(&1, article_id))
     |> reload_article_in_lists(article_id)
     |> put_flash(:error, "Analysis failed: #{format_error(reason)}")}
  end

  def handle_info({:watchlist_changed, _user_id}, socket) do
    actor = socket.assigns.current_user
    watchlist = load_watchlist(actor)
    ticker_ids = watchlist_ticker_id_set(watchlist)
    watchlist_news = load_watchlist_news(ticker_ids, actor)

    subscribe_for_articles(watchlist_news)

    {:noreply,
     socket
     |> assign(:watchlist, watchlist)
     |> assign(:watchlist_ticker_ids, ticker_ids)
     |> assign(:watchlist_news, watchlist_news)}
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

    <!-- Morning Brief preview (full width) -->
        <.morning_brief_preview_card news={@morning_brief_preview} />

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
        <!-- Bottom: split news widgets -->
        <div class={[
          "grid grid-cols-1 gap-4",
          @watchlist != [] && "lg:grid-cols-2"
        ]}>
          <.all_news_card
            news={@news}
            analyzing_ids={@analyzing_ids}
            expanded_ids={@expanded_ids}
            analyze_disabled?={is_nil(@current_user.trading_profile)}
          />
          <.watchlist_news_card
            :if={@watchlist != []}
            news={@watchlist_news}
            analyzing_ids={@analyzing_ids}
            expanded_ids={@expanded_ids}
            analyze_disabled?={is_nil(@current_user.trading_profile)}
          />
        </div>
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

  attr :news, :list, required: true

  defp morning_brief_preview_card(assigns) do
    ~H"""
    <section id="dash-morning-brief" class="card bg-base-200 border border-base-300 p-4">
      <div class="flex items-center justify-between mb-3">
        <h2 class="font-semibold">Morning Brief preview</h2>
        <span class="text-xs opacity-60">latest {length(@news)}</span>
      </div>

      <div :if={@news == []} class="italic text-xs opacity-60">
        No news yet
      </div>

      <ul :if={@news != []} class="space-y-1.5">
        <li
          :for={article <- @news}
          class="flex items-start gap-2 text-sm py-1 border-b border-base-300/40 last:border-0"
        >
          <span class={bucket_badge_class(article.published_at)}>
            {bucket_label(article.published_at)}
          </span>
          <span class="flex-1 min-w-0 truncate">
            {article.title}
          </span>
          <span :if={article.ticker} class="badge badge-outline badge-sm shrink-0">
            {article.ticker.symbol}
          </span>
          <a
            :if={article.url}
            href={article.url}
            target="_blank"
            rel="noopener noreferrer"
            onclick="return confirm('외부 링크로 이동합니다. 계속하시겠습니까?')"
            class="text-xs opacity-60 hover:opacity-100 shrink-0"
          >
            Detail ↗
          </a>
          <span class="text-xs opacity-60 whitespace-nowrap shrink-0 w-16 text-right">
            {brief_time_ago(article.published_at)}
          </span>
        </li>
      </ul>

      <div class="flex justify-end mt-3">
        <.link navigate={~p"/morning"} class="btn btn-ghost btn-sm">
          More <.icon name="hero-arrow-right" class="size-3" />
        </.link>
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
        Add tickers on <.link navigate={~p"/watchlist"} class="underline">/watchlist</.link>
      </div>

      <ul
        :if={@watchlist != []}
        class="grid grid-cols-2 sm:grid-cols-3 gap-x-6 gap-y-1.5 text-sm"
      >
        <li :for={item <- @watchlist} class="flex items-center justify-between">
          <.link navigate={~p"/feed"} class="font-bold hover:underline">
            {item.ticker.symbol}
          </.link>
          <ArticleComponents.price_label
            id={"watchlist-price-#{item.ticker.symbol}"}
            symbol={item.ticker.symbol}
            initial_price={item.ticker.last_price}
            class="opacity-60 tabular-nums"
          />
        </li>
      </ul>
    </section>
    """
  end

  attr :news, :list, required: true
  attr :analyzing_ids, :any, required: true
  attr :expanded_ids, :any, required: true
  attr :analyze_disabled?, :boolean, required: true

  defp all_news_card(assigns) do
    ~H"""
    <section id="dash-all-news" class="card bg-base-200 border border-base-300 p-4">
      <h2 class="font-semibold mb-3">All news</h2>

      <div :if={@news == []} class="italic text-xs opacity-60">
        No news yet
      </div>

      <div :if={@news != []} class="space-y-2">
        <ArticleComponents.article_card
          :for={article <- @news}
          article={article}
          analysis={extract_analysis(article)}
          analyzing?={MapSet.member?(@analyzing_ids, article.id)}
          analyze_disabled?={@analyze_disabled?}
          expanded?={MapSet.member?(@expanded_ids, article.id)}
          context="all"
        />
      </div>
    </section>
    """
  end

  attr :news, :list, required: true
  attr :analyzing_ids, :any, required: true
  attr :expanded_ids, :any, required: true
  attr :analyze_disabled?, :boolean, required: true

  defp watchlist_news_card(assigns) do
    ~H"""
    <section id="dash-watchlist-news" class="card bg-base-200 border border-base-300 p-4">
      <h2 class="font-semibold mb-3">My watchlist news</h2>

      <div :if={@news == []} class="italic text-xs opacity-60">
        No news for your watchlist tickers yet.
      </div>

      <div :if={@news != []} class="space-y-2">
        <ArticleComponents.article_card
          :for={article <- @news}
          article={article}
          analysis={extract_analysis(article)}
          analyzing?={MapSet.member?(@analyzing_ids, article.id)}
          analyze_disabled?={@analyze_disabled?}
          expanded?={MapSet.member?(@expanded_ids, article.id)}
          context="watchlist"
        />
      </div>
    </section>
    """
  end

  #
  # ── helpers ─────────────────────────────────────────────────────

  defp load_watchlist(actor) do
    case Tickers.list_watchlist(actor.id, actor: actor) do
      {:ok, items} -> items
      _ -> []
    end
  end

  defp watchlist_ticker_id_set(watchlist) do
    watchlist
    |> Enum.map(& &1.ticker_id)
    |> MapSet.new()
  end

  defp load_news(actor) do
    # `:recent` sorts by `id: :desc` for keyset cursor stability
    # (LON-100), which is ingest order — not source-publish order.
    # Dashboard is a single-page snapshot, so we re-sort by
    # `published_at` client-side. Cheap for 10 articles.
    case News.list_recent_articles(
           load: [:ticker, :news_analysis],
           actor: actor,
           page: [limit: @news_limit]
         ) do
      {:ok, %Ash.Page.Keyset{results: articles}} -> sort_by_published(articles)
      _ -> []
    end
  end

  defp load_watchlist_news(ticker_ids, actor) do
    if MapSet.size(ticker_ids) == 0 do
      []
    else
      case News.list_recent_articles_for_tickers(MapSet.to_list(ticker_ids),
             load: [:ticker, :news_analysis],
             actor: actor
           ) do
        {:ok, articles} -> sort_by_published(articles)
        _ -> []
      end
    end
  end

  # Morning Brief preview uses the `:morning_brief` action (sort by
  # `published_at: :desc` natively, with `id: :desc` tiebreak), unlike
  # `:recent` which sorts by id for keyset cursor stability.
  defp load_morning_brief_preview(actor) do
    since = DateTime.add(DateTime.utc_now(), -24 * 3600, :second)

    case News.list_morning_brief(%{since: since},
           load: [:ticker],
           actor: actor,
           page: [limit: @news_limit]
         ) do
      {:ok, %Ash.Page.Keyset{results: articles}} -> articles
      _ -> []
    end
  end

  defp sort_by_published(articles) do
    Enum.sort_by(articles, & &1.published_at, {:desc, DateTime})
  end

  defp subscribe_for_articles(articles) do
    articles
    |> Enum.map(& &1.id)
    |> Enum.uniq()
    |> Enum.each(&Analysis.Events.subscribe_for_article/1)
  end

  defp spawn_analyzer(article, actor, parent) do
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

  defp replace_article_in_lists(socket, %{id: id} = article) do
    socket
    |> assign(:news, replace_in_list(socket.assigns.news, id, article))
    |> assign(
      :watchlist_news,
      replace_in_list(socket.assigns.watchlist_news, id, article)
    )
  end

  defp replace_in_list(list, id, article) do
    Enum.map(list, fn
      %{id: ^id} -> article
      other -> other
    end)
  end

  defp reload_article_in_lists(socket, article_id) do
    case News.get_article(article_id,
           load: [:ticker, :news_analysis],
           actor: socket.assigns.current_user
         ) do
      {:ok, article} -> replace_article_in_lists(socket, article)
      {:error, _} -> socket
    end
  end

  defp extract_analysis(%{news_analysis: %LongOrShort.Analysis.NewsAnalysis{} = a}), do: a
  defp extract_analysis(_), do: nil

  defp bucket_label(dt) do
    case Bucket.bucket_for(dt) do
      :overnight -> "Overnight"
      :premarket -> "Premarket"
      :opening -> "Opening"
      :regular -> "Regular"
      :afterhours -> "After-hours"
      :other -> "Older"
    end
  end

  defp bucket_badge_class(dt) do
    color =
      case Bucket.bucket_for(dt) do
        :overnight -> "badge-info"
        :premarket -> "badge-warning"
        :opening -> "badge-success"
        :regular -> "badge-ghost"
        :afterhours -> "badge-primary"
        :other -> "badge-ghost opacity-60"
      end

    "badge badge-sm shrink-0 " <> color
  end

  defp brief_time_ago(%DateTime{} = dt) do
    seconds = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      seconds < 60 -> "now"
      seconds < 3600 -> "#{div(seconds, 60)}m"
      seconds < 86_400 -> "#{div(seconds, 3600)}h"
      true -> "#{div(seconds, 86_400)}d"
    end
  end

  defp format_error({:ai_call_failed, _}), do: "AI provider failed — try again."
  defp format_error(:no_tool_call), do: "Model returned an unexpected response."
  defp format_error({:invalid_enum, field, value}), do: "Bad #{field} value: #{inspect(value)}"
  defp format_error(:no_trading_profile), do: "Set up your TradingProfile first."
  defp format_error(reason), do: inspect(reason)

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
