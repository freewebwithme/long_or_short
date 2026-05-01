defmodule LongOrShortWeb.FeedLive do
  @moduledoc """
  Real-time news feed page. Subscribes to:

  * `News.Events` — to prepend newly-ingested articles to the stream
  * `Analysis.Events` — to flip cards to "analyzing…" / render result
    badges as analyses move through pending → complete | failed

  Articles render as a LiveView stream so the feed doesn't hold an
  unbounded list in socket assigns. Latest analysis per article is
  kept in a separate `:analyses` map keyed by `article_id` for cheap
  card lookup; that map is bounded in practice by the visible stream.
  """
  use LongOrShortWeb, :live_view

  alias LongOrShortWeb.Format
  alias LongOrShort.{Analysis, News}
  alias LongOrShort.Analysis.{Events, RepetitionAnalyzer}

  @initial_limit 30

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      News.Events.subscribe()
      Events.subscribe()
      Phoenix.PubSub.subscribe(LongOrShort.PubSub, "prices")
    end

    filter = empty_filter()

    socket =
      socket
      |> assign(:filter, filter)
      |> load_articles_with_filter(filter)

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

  def handle_info({:price_tick, symbol, price}, socket) do
    {:noreply, push_event(socket, "price_tick", %{symbol: symbol, price: Format.price(price)})}
  end

  @impl true
  def handle_info({:new_article, article}, socket) do
    case News.get_article(article.id,
           load: [:ticker],
           actor: socket.assigns.current_user
         ) do
      {:ok, article} ->
        if matches_filter?(article, socket.assigns.filter) do
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

  def handle_info({event, %{article_id: id} = analysis}, socket)
      when event in [
             :repetition_analysis_started,
             :repetition_analysis_complete,
             :repetition_analysis_failed
           ] do
    socket = update(socket, :analyses, &Map.put(&1, id, analysis))

    case News.get_article(id, load: [:ticker], actor: socket.assigns.current_user) do
      {:ok, article} -> {:noreply, stream_insert(socket, :articles, article)}
      {:error, _} -> {:noreply, socket}
    end
  end

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
            class="border border-base-300 rounded p-3 bg-base-200 shadow-sm flex gap-3 items-start"
          >
            <div class="text-xs opacity-60 w-20 flex-shrink-0">
              <time datetime={DateTime.to_iso8601(article.published_at)}>
                {Format.relative_time(article.published_at)}
              </time>
            </div>

            <div class="w-20 flex-shrink-0">
              <div class="font-bold">{article.ticker.symbol}</div>
              <span
                id={"price-#{article.id}"}
                phx-hook=".PriceLabel"
                data-symbol={article.ticker.symbol}
                data-initial-price={Format.price(article.ticker.last_price)}
                class="text-xs opacity-60"
              >
              </span>
            </div>

            <div class="flex-grow">{article.title}</div>
            <div class="text-xs px-2 py-0.5 rounded bg-base-300 flex-shrink-0">
              {article.source}
            </div>

            <.analysis_cell analysis={Map.get(@analyses, article.id)} article_id={article.id} />
          </div>
        </div>
      </div>
    </Layouts.app>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".PriceLabel">
      export default {
        mounted() {
          this.symbol = this.el.dataset.symbol
          const initial = this.el.dataset.initialPrice
          if (initial && initial !== "") {
            this.el.textContent = `$${initial}`
          }
          this.handler = (e) => {
            if (e.detail.symbol === this.symbol) {
              this.el.textContent = `$${e.detail.price}`
            }
          }
          window.addEventListener("phx:price_tick", this.handler)
        },
        destroyed() {
          window.removeEventListener("phx:price_tick", this.handler)
        }
      }
    </script>
    """
  end

  # ── analysis cell rendering ────────────────────────────────────────

  attr :analysis, :any, required: true
  attr :article_id, :string, required: true

  defp analysis_cell(%{analysis: nil} = assigns) do
    ~H"""
    <button
      type="button"
      phx-click="analyze"
      phx-value-id={@article_id}
      class="text-xs px-2 py-0.5 rounded bg-primary text-primary-content flex-shrink-0 hover:bg-primary-focus"
    >
      Analyze
    </button>
    """
  end

  defp analysis_cell(%{analysis: %{status: :pending}} = assigns) do
    ~H"""
    <div class="text-xs italic opacity-60 flex-shrink-0">analyzing…</div>
    """
  end

  defp analysis_cell(%{analysis: %{status: :complete} = a} = assigns) do
    assigns = assign(assigns, :a, a)

    ~H"""
    <div class="flex gap-1 items-center text-xs flex-shrink-0">
      <span
        class={"w-2 h-2 rounded-full #{fatigue_color(@a.fatigue_level)}"}
        title={"fatigue: #{@a.fatigue_level}"}
      />
      <span :if={@a.is_repetition} class="opacity-80">🔁 {@a.repetition_count}×</span>
      <span :if={@a.theme} class="px-1.5 py-0.5 rounded bg-base-300 opacity-80 max-w-[10rem] truncate">
        {@a.theme}
      </span>
    </div>
    """
  end

  defp analysis_cell(%{analysis: %{status: :failed} = a} = assigns) do
    assigns = assign(assigns, :a, a)

    ~H"""
    <div class="text-xs flex-shrink-0" title={@a.error_message || "analysis failed"}>
      <span class="text-error">⚠</span>
    </div>
    """
  end

  # ── helpers ────────────────────────────────────────────────────────

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

  defp fatigue_color(:low), do: "bg-success"
  defp fatigue_color(:medium), do: "bg-warning"
  defp fatigue_color(:high), do: "bg-error"
  defp fatigue_color(_), do: "bg-base-300"

  defp empty_filter, do: %{price_min: nil, price_max: nil, float_max: nil}

  defp load_articles_with_filter(socket, filter) do
    actor = socket.assigns.current_user

    args =
      %{limit: @initial_limit}
      |> maybe_put(:price_min, filter.price_min)
      |> maybe_put(:price_max, filter.price_max)
      |> maybe_put(:float_max, filter.float_max)

    {:ok, articles} =
      News.list_recent_articles(args, load: [:ticker], actor: actor)

    analyses = load_latest_analyses(articles, actor)

    socket
    |> assign(:article_count, length(articles))
    |> assign(:analyses, analyses)
    |> stream(:articles, articles, reset: true)
  end

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
