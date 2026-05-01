defmodule LongOrShortWeb.DashboardLive do
  @moduledoc """
  Dashboard skeleton — landing for authenticated users.
  Composes four widgets: ticker search, indices, condensed news,
  watchlist quick view. Each rendered as a placeholder card here;
  real content arrives via separate sub-tickets (LON-73 — LON-76).
  """
  use LongOrShortWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(LongOrShort.PubSub, "prices")
      LongOrShort.News.Events.subscribe()
    end

    {:ok, socket}
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
            hint="NASDAQ · DJIA · S&P 500"
          />
          <.placeholder_card
            id="dash-news"
            title="Latest news"
            hint="Top headlines across the watchlist"
          />
        </div>
        <.placeholder_card
          id="dash-watchlist"
          title="Watchlist"
          hint="Live prices for tracked symbols"
        />
      </div>
    </Layouts.app>
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
end
