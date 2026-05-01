defmodule LongOrShortWeb.DashboardLive do
  @moduledoc """
  Dashboard skeleton — landing for authenticated users.

  Composes four widgets: ticker search, indices, condensed news,
  watchlist quick view. Search/indices/news still placeholder cards;
  watchlist is wired to the file-backed watchlist (LON-64) with live
  prices via the shared `PriceLabel` hook (LON-60).
  """
  use LongOrShortWeb, :live_view

  alias LongOrShortWeb.Format
  alias LongOrShort.Tickers
  alias LongOrShort.Tickers.Watchlist

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(LongOrShort.PubSub, "prices")
      LongOrShort.News.Events.subscribe()
    end

    {:ok, assign(socket, :watchlist, load_watchlist(socket.assigns.current_user))}
  end

  @impl true
  def handle_info({:price_tick, symbol, price}, socket) do
    {:noreply, push_event(socket, "price_tick", %{symbol: symbol, price: Format.price(price)})}
  end

  def handle_info({:new_article, _article}, socket) do
    # News widget will handle this in LON-73; for now ignore so the
    # subscription doesn't crash the LV.
    {:noreply, socket}
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
          <.placeholder_card
            id="dash-news"
            title="Latest news"
            hint="Top headlines across the watchlist"
          />
        </div>

        <.watchlist_card watchlist={@watchlist} />
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
          <span
            id={"watchlist-price-#{item.symbol}"}
            phx-hook="PriceLabel"
            data-symbol={item.symbol}
            data-initial-price={Format.price(item.last_price)}
            class="opacity-60 tabular-nums"
          >
          </span>
        </li>
      </ul>
    </section>
    """
  end

  defp load_watchlist(actor) do
    Enum.map(Watchlist.symbols(), fn symbol ->
      case Tickers.get_ticker_by_symbol(symbol, actor: actor) do
        {:ok, ticker} -> %{symbol: symbol, last_price: ticker.last_price}
        _ -> %{symbol: symbol, last_price: nil}
      end
    end)
  end
end
