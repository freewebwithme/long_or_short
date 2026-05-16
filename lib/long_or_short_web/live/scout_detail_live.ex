defmodule LongOrShortWeb.ScoutDetailLive do
  @moduledoc """
  Read-only detail view for a specific `TickerBriefing` row.

  Entry point: `/scout/b/:id`. Linked from the Scout recent-scouts
  panel and the Dashboard recent-scouts widget. Separate from
  `ScoutLive` because the run-flow page is state-machine driven
  (`:idle → :ready → :running → :done`) and only renders the *latest
  fresh* briefing — a stale recent scout would fall back to `:ready`
  and hide its own content. This view loads the row by primary key
  and renders regardless of freshness.
  """

  use LongOrShortWeb, :live_view

  alias LongOrShort.Research
  alias LongOrShortWeb.Live.Research.ScoutCard

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user = socket.assigns.current_user

    case Research.get_ticker_briefing(id, actor: user) do
      {:ok, briefing} ->
        {:ok,
         socket
         |> assign(:briefing, briefing)
         |> assign(:page_title, "Scout · #{briefing.symbol}")}

      _ ->
        {:ok,
         socket
         |> put_flash(:error, "Briefing not found or no longer available.")
         |> push_navigate(to: ~p"/scout")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app current_path={@current_path} current_user={@current_user} flash={@flash}>
      <div class="max-w-3xl mx-auto space-y-4">
        <div class="flex items-center justify-between">
          <.link navigate={~p"/scout"} class="link link-hover text-sm opacity-70">
            ← Back to Scout
          </.link>
          <.link
            navigate={~p"/scout/#{@briefing.symbol}"}
            class="btn btn-sm btn-outline"
          >
            Run new Scout for {@briefing.symbol}
          </.link>
        </div>

        <ScoutCard.scout_result_card briefing={@briefing} />
      </div>
    </Layouts.app>
    """
  end
end
