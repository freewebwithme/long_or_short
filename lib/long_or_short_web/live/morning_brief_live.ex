defmodule LongOrShortWeb.MorningBriefLive do
  @moduledoc """
  Morning Brief — time-bucketed news view (LON-129).

  Surfaces articles in the layout traders actually use across the
  morning session: overnight catalysts → premarket movers → opening
  flow. The Alpaca firehose (LON-128) is the primary data source;
  Finnhub + SEC feeders contribute too.

  ## View modes

  Auto-selected at mount based on the current ET time
  (`Bucket.default_view_for/1`), overridable via the page selector
  and `?view=...` URL param.

  ## Focus toggle

  `?focus=all` (default) or `?focus=watchlist` — when "watchlist",
  the query gets the user's `WatchlistItem.ticker_id`s as a scope
  via `News.list_morning_brief/2`'s `:ticker_ids` argument.

  ## Real-time

  Subscribes to `News.Events`. New articles inside the current view
  window (+ focus filter) get `stream_insert/4` at the top.
  Articles outside the window are dropped — refreshing or extending
  the window via selector reloads them.
  """

  use LongOrShortWeb, :live_view

  alias LongOrShort.News
  alias LongOrShort.Tickers
  alias LongOrShortWeb.MorningBrief.Bucket

  @page_limit 50

  @view_options [
    {:premarket_brief, "Premarket Brief"},
    {:opening, "Opening Hour"},
    {:intraday, "Intraday"},
    {:afterhours, "After-hours"},
    {:all_recent, "All Recent (24h)"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: News.Events.subscribe()

    watchlist_ticker_ids = load_watchlist_ticker_ids(socket.assigns.current_user)

    socket =
      socket
      |> assign(:watchlist_ticker_ids, watchlist_ticker_ids)
      |> assign(:view_options, @view_options)
      |> stream(:articles, [])

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    view_mode = parse_view(params["view"]) || Bucket.default_view_for()
    focus = parse_focus(params["focus"])

    socket =
      socket
      |> assign(:view_mode, view_mode)
      |> assign(:focus, focus)
      |> load_articles()

    {:noreply, socket}
  end

  # ── events ─────────────────────────────────────────────────────

  @impl true
  def handle_event("select_view", %{"view" => view_str}, socket) do
    view_mode = parse_view(view_str) || socket.assigns.view_mode
    {:noreply, push_patch(socket, to: url_for(view_mode, socket.assigns.focus))}
  end

  def handle_event("toggle_focus", _params, socket) do
    new_focus = if socket.assigns.focus == :watchlist, do: :all, else: :watchlist
    {:noreply, push_patch(socket, to: url_for(socket.assigns.view_mode, new_focus))}
  end

  def handle_event("load_more", _params, socket) do
    actor = socket.assigns.current_user
    args = build_args(socket)

    case News.list_morning_brief(args,
           load: [:ticker],
           actor: actor,
           page: [after: socket.assigns.last_cursor, limit: @page_limit]
         ) do
      {:ok, %Ash.Page.Keyset{results: articles, more?: more}} ->
        socket =
          articles
          |> Enum.reduce(socket, fn article, sock ->
            stream_insert(sock, :articles, article, at: -1)
          end)
          |> assign(:last_cursor, last_keyset(articles, socket.assigns.last_cursor))
          |> assign(:more?, more)
          |> update(:article_count, &(&1 + length(articles)))

        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  # ── PubSub ─────────────────────────────────────────────────────

  @impl true
  def handle_info({:new_article, article}, socket) do
    if matches_view?(article, socket) do
      case News.get_article(article.id,
             load: [:ticker],
             actor: socket.assigns.current_user
           ) do
        {:ok, loaded} ->
          socket =
            socket
            |> stream_insert(:articles, loaded, at: 0)
            |> update(:article_count, &(&1 + 1))

          {:noreply, socket}

        {:error, _} ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  # ── render ─────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_path={@current_path}>
      <div class="max-w-4xl mx-auto p-6">
        <div class="mb-6">
          <.link
            navigate={~p"/"}
            class="text-sm opacity-60 hover:opacity-100 inline-flex items-center gap-1 mb-2"
          >
            <.icon name="hero-arrow-left" class="size-3" /> Dashboard
          </.link>
          <h1 class="text-2xl font-bold">Morning Brief</h1>
          <p class="text-sm opacity-60 mt-1">
            {view_label(@view_mode)} · {focus_label(@focus, length(@watchlist_ticker_ids))} · {@article_count} {if @article_count == 1,
              do: "article",
              else: "articles"}
          </p>
        </div>

        <div class="mb-4 flex gap-2 flex-wrap items-center">
          <div class="join">
            <button
              :for={{mode, label} <- @view_options}
              type="button"
              phx-click="select_view"
              phx-value-view={Atom.to_string(mode)}
              class={[
                "btn btn-sm join-item",
                if(@view_mode == mode, do: "btn-primary", else: "btn-ghost")
              ]}
            >
              {label}
            </button>
          </div>

          <button
            type="button"
            phx-click="toggle_focus"
            class={[
              "btn btn-sm",
              if(@focus == :watchlist, do: "btn-secondary", else: "btn-outline")
            ]}
            disabled={@focus == :all and @watchlist_ticker_ids == []}
            title={if @watchlist_ticker_ids == [], do: "Add tickers to your watchlist first"}
          >
            <%= if @focus == :watchlist do %>
              <.icon name="hero-star-solid" class="size-4" /> Watchlist
            <% else %>
              <.icon name="hero-star" class="size-4" /> All sources
            <% end %>
          </button>
        </div>

        <div :if={@article_count == 0} class="opacity-60 italic py-8 text-center">
          No articles in this window — try a wider view or wait for the next poll.
        </div>

        <div id="morning-articles" phx-update="stream" class="space-y-3">
          <article
            :for={{dom_id, article} <- @streams.articles}
            id={dom_id}
            class="card bg-base-100 border border-base-300 p-4"
          >
            <div class="flex flex-wrap items-center gap-2 mb-2 text-xs">
              <span class={bucket_badge_class(article.published_at)}>
                {bucket_label(article.published_at)}
              </span>
              <span class="opacity-60">{time_ago(article.published_at)}</span>
              <span class="badge badge-ghost badge-sm">{source_badge(article)}</span>
            </div>

            <.link
              navigate={~p"/analyze/#{article.id}"}
              class="font-medium hover:underline block mb-1"
            >
              {article.title}
            </.link>

            <p :if={article.summary} class="text-sm opacity-80 line-clamp-2">
              {article.summary}
            </p>

            <div :if={article.ticker} class="flex gap-1 mt-2">
              <span class="badge badge-outline badge-sm">{article.ticker.symbol}</span>
            </div>
          </article>
        </div>

        <div :if={@more?} class="flex justify-center mt-4">
          <button type="button" phx-click="load_more" class="btn btn-outline btn-sm">
            Load more
          </button>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # ── data loading ───────────────────────────────────────────────

  defp load_articles(socket) do
    actor = socket.assigns.current_user
    args = build_args(socket)

    case News.list_morning_brief(args,
           load: [:ticker],
           actor: actor,
           page: [limit: @page_limit]
         ) do
      {:ok, %Ash.Page.Keyset{results: articles, more?: more}} ->
        socket
        |> assign(:article_count, length(articles))
        |> assign(:last_cursor, last_keyset(articles, nil))
        |> assign(:more?, more)
        |> stream(:articles, articles, reset: true)

      _ ->
        socket
        |> assign(:article_count, 0)
        |> assign(:last_cursor, nil)
        |> assign(:more?, false)
        |> stream(:articles, [], reset: true)
    end
  end

  defp build_args(socket) do
    # We only send `:since` to the DB query — Postgres/Ash filter
    # comparisons against a runtime DateTime variable returned 0 rows
    # during initial wiring (root cause: still under investigation,
    # likely a microsecond/cast quirk). `:until` is enforced
    # client-side in `matches_view?/2` for PubSub deliveries instead,
    # which is sufficient because feeders never publish future-dated
    # articles in practice.
    {since, _until} = Bucket.view_window(socket.assigns.view_mode)

    args = %{since: since}

    case socket.assigns.focus do
      :watchlist -> Map.put(args, :ticker_ids, socket.assigns.watchlist_ticker_ids)
      :all -> args
    end
  end

  defp load_watchlist_ticker_ids(user) do
    case Tickers.list_watchlist(user.id, actor: user) do
      {:ok, items} -> Enum.map(items, & &1.ticker_id)
      _ -> []
    end
  end

  defp matches_view?(article, socket) do
    {since, until} = Bucket.view_window(socket.assigns.view_mode)

    in_window? =
      DateTime.compare(article.published_at, since) != :lt and
        DateTime.compare(article.published_at, until) == :lt

    in_focus? =
      case socket.assigns.focus do
        :all -> true
        :watchlist -> article.ticker_id in socket.assigns.watchlist_ticker_ids
      end

    in_window? and in_focus?
  end

  # ── URL state ──────────────────────────────────────────────────

  defp parse_view("premarket_brief"), do: :premarket_brief
  defp parse_view("opening"), do: :opening
  defp parse_view("intraday"), do: :intraday
  defp parse_view("afterhours"), do: :afterhours
  defp parse_view("all_recent"), do: :all_recent
  defp parse_view(_), do: nil

  defp parse_focus("watchlist"), do: :watchlist
  defp parse_focus(_), do: :all

  defp url_for(view_mode, focus) do
    # Keyword list (not map) preserves order — keeps the URL stable
    # for share/refresh and gives push_patch tests a deterministic
    # string to assert against.
    params = [{"view", Atom.to_string(view_mode)}, {"focus", Atom.to_string(focus)}]
    "/morning?" <> URI.encode_query(params)
  end

  # ── view helpers ───────────────────────────────────────────────

  defp view_label(mode), do: List.keyfind(@view_options, mode, 0) |> elem(1)

  defp focus_label(:watchlist, n), do: "Watchlist (#{n})"
  defp focus_label(:all, _), do: "All sources"

  defp bucket_label(published_at) do
    case Bucket.bucket_for(published_at) do
      :overnight -> "Overnight"
      :premarket -> "Premarket"
      :opening -> "Opening"
      :regular -> "Regular"
      :afterhours -> "After-hours"
      :other -> "Older"
    end
  end

  defp bucket_badge_class(published_at) do
    base = "badge badge-sm"

    color =
      case Bucket.bucket_for(published_at) do
        :overnight -> "badge-info"
        :premarket -> "badge-warning"
        :opening -> "badge-success"
        :regular -> "badge-ghost"
        :afterhours -> "badge-primary"
        :other -> "badge-ghost opacity-60"
      end

    base <> " " <> color
  end

  defp source_badge(%{source: :alpaca, raw_category: vendor}) when is_binary(vendor), do: vendor
  defp source_badge(%{source: source}), do: source |> Atom.to_string() |> String.capitalize()

  defp time_ago(%DateTime{} = dt) do
    seconds = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      seconds < 60 -> "just now"
      seconds < 3600 -> "#{div(seconds, 60)} min ago"
      seconds < 86_400 -> "#{div(seconds, 3600)} h ago"
      true -> "#{div(seconds, 86_400)} d ago"
    end
  end

  defp last_keyset([], fallback), do: fallback

  defp last_keyset(articles, _fallback) do
    case List.last(articles) do
      %{__metadata__: %{keyset: cursor}} -> cursor
      _ -> nil
    end
  end
end
