defmodule LongOrShortWeb.FeedLive do
  @moduledoc """
  Real-time news feed page. Subscribes to the News.Events PubSub topic
  and prepends each newly-broadcast Article to the visible stream.

  Rendered as a LiveView stream so we don't
  hold an unbounded list in socket assigns. A separate `:article_count`
  assign tracks the total — streams themselves are not enumerable.

  Authentication: requires a logged-in user (`live_user_required` is
  applied via the `ash_authentication_live_session` block in the
  router).
  """

  use LongOrShortWeb, :live_view

  alias LongOrShort.News

  @initial_limit 30

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: News.Events.subscribe()

    {:ok, articles} =
      News.list_recent_articles(
        %{limit: @initial_limit},
        load: [:ticker],
        actor: socket.assigns.current_user
      )

    socket =
      socket
      |> assign(:article_count, length(articles))
      |> stream(:articles, articles)

    {:ok, socket}
  end

  @impl true
  def handle_info({:new_article, article}, socket) do
    case News.get_article(article.id, load: [:ticker], actor: socket.assigns.current_user) do
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
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

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
