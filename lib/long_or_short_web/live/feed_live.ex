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

  alias LongOrShort.{Analysis, News}
  alias LongOrShort.Analysis.{Events, RepetitionAnalyzer}

  @initial_limit 30

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      News.Events.subscribe()
      Events.subscribe()
    end

    actor = socket.assigns.current_user

    {:ok, articles} =
      News.list_recent_articles(
        %{limit: @initial_limit},
        load: [:ticker],
        actor: actor
      )

    analyses = load_latest_analyses(articles, actor)

    socket =
      socket
      |> assign(:article_count, length(articles))
      |> assign(:analyses, analyses)
      |> stream(:articles, articles)

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
  def handle_info({:new_article, article}, socket) do
    case News.get_article(article.id,
           load: [:ticker],
           actor: socket.assigns.current_user
         ) do
      {:ok, article} ->
        socket =
          socket
          |> stream_insert(:articles, article, at: 0)
          |> update(:article_count, &(&1 + 1))

        {:noreply, socket}

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
    <Layouts.app flash={@flash}>
      <div class="max-w-4xl mx-auto p-6">
        <div class="mb-6">
          <h1 class="text-2xl font-bold">News Feed</h1>
          <p class="text-sm opacity-60 mt-1">
            {@article_count} {if @article_count == 1, do: "update", else: "updates"} received
          </p>
        </div>

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
                {relative_time(article.published_at)}
              </time>
            </div>
            <div class="font-bold w-16 flex-shrink-0">{article.ticker.symbol}</div>
            <div class="flex-grow">{article.title}</div>
            <div class="text-xs px-2 py-0.5 rounded bg-base-300 flex-shrink-0">
              {article.source}
            </div>

            <.analysis_cell analysis={Map.get(@analyses, article.id)} article_id={article.id} />
          </div>
        </div>
      </div>
    </Layouts.app>
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

  defp relative_time(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86_400)}d ago"
    end
  end
end
