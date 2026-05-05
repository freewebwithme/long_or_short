defmodule LongOrShortWeb.FeedLive do
  @moduledoc """
  Real-time news feed page.

  Subscribes to:

    * `News.Events` — prepends newly-ingested articles to the stream
    * `Analysis.Events.subscribe_for_article/1` — once per article in the
      stream; delivers `{:news_analysis_ready, _}` after the analyzer
      finishes
    * `"prices"` — live last_price ticks

  Analyze flow (LON-83):

    1. User clicks Analyze → `handle_event("analyze", _, _)`
    2. Article id added to `analyzing_ids` MapSet, card re-rendered with
       the skeleton loading state
    3. `Task.Supervisor` spawns `NewsAnalyzer.analyze/2` (non-blocking)
    4. On success, analyzer broadcasts on `analysis:article:<id>` →
       `handle_info({:news_analysis_ready, _}, _)` re-fetches the article
       with `:news_analysis` preloaded and re-inserts it
    5. On failure, the Task sends `{:analyze_failed, id, reason}` back
       to this LiveView, which surfaces a flash and resets the card

  Detail toggle is parent-owned via `expanded_ids` MapSet so re-render
  via `stream_insert` keeps state in sync.
  """
  use LongOrShortWeb, :live_view

  alias LongOrShortWeb.Format
  alias LongOrShortWeb.Live.Components.ArticleComponents
  alias LongOrShort.{News, Analysis}
  alias LongOrShort.Analysis.NewsAnalyzer

  @initial_limit 30

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      News.Events.subscribe()
      Phoenix.PubSub.subscribe(LongOrShort.PubSub, "prices")
    end

    filter = empty_filter()

    socket =
      socket
      |> assign(:filter, filter)
      |> assign(:analyzing_ids, MapSet.new())
      |> assign(:expanded_ids, MapSet.new())
      |> load_articles_with_filter(filter)

    {:ok, socket}
  end

  # ── Events ─────────────────────────────────────────────────────────

  @impl true
  def handle_event("analyze", %{"id" => article_id}, socket) do
    actor = socket.assigns.current_user

    case News.get_article(article_id, load: [:ticker, :news_analysis], actor: actor) do
      {:ok, article} ->
        spawn_analyzer(article, actor, self())

        socket =
          socket
          |> update(:analyzing_ids, &MapSet.put(&1, article_id))
          |> stream_insert(:articles, article)

        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Article not found.")}
    end
  end

  def handle_event("toggle_detail", %{"id" => article_id}, socket) do
    expanded_ids =
      if MapSet.member?(socket.assigns.expanded_ids, article_id) do
        MapSet.delete(socket.assigns.expanded_ids, article_id)
      else
        MapSet.put(socket.assigns.expanded_ids, article_id)
      end

    socket =
      socket
      |> assign(:expanded_ids, expanded_ids)
      |> refresh_card(article_id)

    {:noreply, socket}
  end

  def handle_event("filter_changed", %{"filter" => params}, socket) do
    filter = parse_filter(params)

    socket =
      socket
      |> assign(:filter, filter)
      |> load_articles_with_filter(filter)

    {:noreply, socket}
  end

  def handle_event("clear_filter", _params, socket) do
    filter = empty_filter()

    socket =
      socket
      |> assign(:filter, filter)
      |> load_articles_with_filter(filter)

    {:noreply, socket}
  end

  # ── PubSub & async ────────────────────────────────────────────────

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
        if matches_filter?(article, socket.assigns.filter) do
          # New article in the feed — subscribe so future analyses on it land
          Analysis.Events.subscribe_for_article(article.id)

          socket =
            socket
            |> stream_insert(:articles, article, at: 0)
            |> update(:article_count, &(&1 + 1))

          {:noreply, socket}
        else
          {:noreply, socket}
        end

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_info({:news_analysis_ready, %{article_id: article_id}}, socket) do
    socket =
      socket
      |> update(:analyzing_ids, &MapSet.delete(&1, article_id))
      |> refresh_card(article_id)

    {:noreply, socket}
  end

  def handle_info({:analyze_failed, article_id, reason}, socket) do
    socket =
      socket
      |> update(:analyzing_ids, &MapSet.delete(&1, article_id))
      |> refresh_card(article_id)
      |> put_flash(:error, "Analysis failed: #{format_error(reason)}")

    {:noreply, socket}
  end

  # ── Render ─────────────────────────────────────────────────────────

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
          <h1 class="text-2xl font-bold">News Feed</h1>
          <p class="text-sm opacity-60 mt-1">
            {@article_count} {if @article_count == 1, do: "update", else: "updates"} received
          </p>
        </div>
        <form
          phx-change="filter_changed"
          phx-debounce="300"
          class="mb-4 flex gap-3 items-end flex-wrap"
        >
          <div>
            <label class="text-xs opacity-60 block">Price min</label>
            <input
              type="number"
              step="0.01"
              name="filter[price_min]"
              value={input_value(@filter.price_min)}
              placeholder="2"
              class="input input-sm input-bordered w-24"
            />
          </div>
          <div>
            <label class="text-xs opacity-60 block">Price max</label>
            <input
              type="number"
              step="0.01"
              name="filter[price_max]"
              value={input_value(@filter.price_max)}
              placeholder="10"
              class="input input-sm input-bordered w-24"
            />
          </div>
          <div>
            <label class="text-xs opacity-60 block">Float max (M)</label>
            <input
              type="number"
              step="1"
              name="filter[float_max]"
              value={input_value_millions(@filter.float_max)}
              placeholder="50"
              class="input input-sm input-bordered w-24"
            />
          </div>
          <button type="button" phx-click="clear_filter" class="btn btn-sm btn-ghost">
            Clear
          </button>
        </form>
        <div :if={@article_count == 0} class="opacity-60 italic py-8 text-center">
          No articles yet — waiting for news...
        </div>
        <div id="articles" phx-update="stream" class="space-y-2">
          <div
            :for={{dom_id, article} <- @streams.articles}
            id={dom_id}
          >
            <ArticleComponents.article_card
              article={article}
              analysis={extract_analysis(article)}
              analyzing?={MapSet.member?(@analyzing_ids, article.id)}
              expanded?={MapSet.member?(@expanded_ids, article.id)}
            />
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # ── helpers ────────────────────────────────────────────────────────

  defp empty_filter, do: %{price_min: nil, price_max: nil, float_max: nil}

  defp load_articles_with_filter(socket, filter) do
    actor = socket.assigns.current_user

    args =
      %{limit: @initial_limit}
      |> maybe_put(:price_min, filter.price_min)
      |> maybe_put(:price_max, filter.price_max)
      |> maybe_put(:float_max, filter.float_max)

    {:ok, articles} =
      News.list_recent_articles(args, load: [:ticker, :news_analysis], actor: actor)

    if connected?(socket) do
      for article <- articles, do: Analysis.Events.subscribe_for_article(article.id)
    end

    socket
    |> assign(:article_count, length(articles))
    |> stream(:articles, articles, reset: true)
  end

  defp refresh_card(socket, article_id) do
    case News.get_article(article_id,
           load: [:ticker, :news_analysis],
           actor: socket.assigns.current_user
         ) do
      {:ok, article} -> stream_insert(socket, :articles, article)
      {:error, _} -> socket
    end
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

  defp extract_analysis(%{news_analysis: %LongOrShort.Analysis.NewsAnalysis{} = a}), do: a
  defp extract_analysis(_), do: nil

  defp format_error({:ai_call_failed, _}), do: "AI provider failed — try again."
  defp format_error(:no_tool_call), do: "Model returned an unexpected response."
  defp format_error({:invalid_enum, field, value}), do: "Bad #{field} value: #{inspect(value)}"
  defp format_error(:no_trading_profile), do: "Set up your TradingProfile first."
  defp format_error(reason), do: inspect(reason)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp parse_filter(params) do
    %{
      price_min: parse_decimal(params["price_min"]),
      price_max: parse_decimal(params["price_max"]),
      float_max: parse_float_millions(params["float_max"])
    }
  end

  defp parse_decimal(s) when s in [nil, ""], do: nil

  defp parse_decimal(s) when is_binary(s) do
    case Decimal.parse(s) do
      {decimal, _rest} -> decimal
      :error -> nil
    end
  end

  defp parse_float_millions(s) when s in [nil, ""], do: nil

  defp parse_float_millions(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} when n > 0 -> n * 1_000_000
      _ -> nil
    end
  end

  defp matches_filter?(article, filter) do
    ticker = article.ticker

    matches_price_min?(ticker, filter.price_min) and
      matches_price_max?(ticker, filter.price_max) and
      matches_float_max?(ticker, filter.float_max)
  end

  defp matches_price_min?(_ticker, nil), do: true
  defp matches_price_min?(%{last_price: nil}, _min), do: false
  defp matches_price_min?(%{last_price: lp}, min), do: Decimal.compare(lp, min) != :lt

  defp matches_price_max?(_ticker, nil), do: true
  defp matches_price_max?(%{last_price: nil}, _max), do: false
  defp matches_price_max?(%{last_price: lp}, max), do: Decimal.compare(lp, max) != :gt

  defp matches_float_max?(_ticker, nil), do: true
  defp matches_float_max?(%{float_shares: nil}, _max), do: false
  defp matches_float_max?(%{float_shares: fs}, max), do: fs <= max

  defp input_value(nil), do: ""
  defp input_value(%Decimal{} = d), do: Decimal.to_string(d)
  defp input_value(v), do: to_string(v)

  defp input_value_millions(nil), do: ""
  defp input_value_millions(n) when is_integer(n), do: to_string(div(n, 1_000_000))
end
