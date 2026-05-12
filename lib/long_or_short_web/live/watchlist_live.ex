defmodule LongOrShortWeb.WatchlistLive do
  @moduledoc """
  Per-user watchlist management page (/watchlist).

  Displays the trader's personal watchlist (DB-backed WatchlistItem rows from
  LON-92) and allows adding tickers via the shared TickerAutocomplete component
  and removing them via a confirm-gated button.

  Add flow:
    1. User types into the autocomplete input.
    2. `search_ticker` event fires → `Tickers.search_tickers/2` populates suggestions.
    3. User clicks a suggestion → `add_ticker` event with `%{"symbol" => ...}`.
    4. Look up the ticker, check for duplicates, call `Tickers.add_to_watchlist/2`.
    5. Prepend the new item to `@items`, clear the search state.

  Remove flow:
    1. User clicks the Remove button (data-confirm guards against accidents).
    2. `remove_ticker` event fires with `%{"id" => item_id}`.
    3. Call `Tickers.remove_from_watchlist/2`, optimistically remove from assigns.
  """
  use LongOrShortWeb, :live_view

  alias LongOrShort.Tickers
  alias LongOrShort.Tickers.WatchlistEvents
  alias LongOrShortWeb.Layouts
  alias LongOrShortWeb.Live.Components.TickerAutocomplete

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user

    items =
      case Tickers.list_watchlist(actor.id, actor: actor) do
        {:ok, list} -> list
        _ -> []
      end

    socket =
      socket
      |> assign(:items, items)
      |> assign(:search_query, "")
      |> assign(:search_results, [])

    {:ok, socket}
  end

  @impl true
  def handle_event("search_ticker", %{"query" => query}, socket) do
    {trimmed, results} =
      LongOrShortWeb.Live.TickerSearchHelper.search(query, socket.assigns.current_user)

    {:noreply,
     socket
     |> assign(:search_query, trimmed)
     |> assign(:search_results, results)}
  end

  def handle_event("add_ticker", %{"symbol" => symbol}, socket) do
    actor = socket.assigns.current_user

    already_in_watchlist? =
      Enum.any?(socket.assigns.items, fn item -> item.ticker.symbol == symbol end)

    if already_in_watchlist? do
      {:noreply,
       socket
       |> put_flash(:info, "#{symbol} is already in your watchlist.")
       |> assign(:search_query, "")
       |> assign(:search_results, [])}
    else
      with {:ok, ticker} <- Tickers.get_ticker_by_symbol(symbol, actor: actor),
           {:ok, item} <-
             Tickers.add_to_watchlist(%{user_id: actor.id, ticker_id: ticker.id}, actor: actor) do
        item_with_ticker = %{item | ticker: ticker}
        WatchlistEvents.broadcast_changed(actor.id)

        {:noreply,
         socket
         |> assign(:items, [item_with_ticker | socket.assigns.items])
         |> assign(:search_query, "")
         |> assign(:search_results, [])}
      else
        _ ->
          {:noreply,
           socket
           |> put_flash(:error, "Could not add #{symbol} to your watchlist.")
           |> assign(:search_query, "")
           |> assign(:search_results, [])}
      end
    end
  end

  def handle_event("clear_search", _params, socket) do
    {:noreply,
     socket
     |> assign(:search_query, "")
     |> assign(:search_results, [])}
  end

  def handle_event("remove_ticker", %{"id" => item_id}, socket) do
    actor = socket.assigns.current_user
    item = Enum.find(socket.assigns.items, &(&1.id == item_id))

    case item do
      nil ->
        {:noreply, socket}

      item ->
        case Tickers.remove_from_watchlist(item, actor: actor) do
          :ok ->
            WatchlistEvents.broadcast_changed(actor.id)

            {:noreply,
             assign(socket, :items, Enum.reject(socket.assigns.items, &(&1.id == item_id)))}

          _ ->
            {:noreply, put_flash(socket, :error, "Failed to remove ticker.")}
        end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_path={@current_path}>
      <div class="space-y-4">
        <section class="card bg-base-200 border border-base-300 p-4">
          <h2 class="font-semibold mb-3">Watchlist</h2>

          <div class="mb-4 max-w-sm">
            <TickerAutocomplete.ticker_autocomplete
              query={@search_query}
              results={@search_results}
              search_event="search_ticker"
              select_event="add_ticker"
              clear_event="clear_search"
            />
          </div>

          <div :if={@items == []} class="italic text-xs opacity-60">
            No tickers yet. Search above to add one.
          </div>

          <ul :if={@items != []} class="divide-y divide-base-300">
            <li :for={item <- @items} class="flex items-center justify-between py-2 text-sm">
              <div class="flex flex-col gap-0.5">
                <span class="font-bold">{item.ticker.symbol}</span>
                <span :if={item.ticker.company_name} class="text-xs opacity-60">
                  {item.ticker.company_name}
                </span>
                <span class="text-xs opacity-40">
                  added {Calendar.strftime(item.created_at, "%Y-%m-%d")}
                </span>
              </div>

              <div class="flex items-center gap-4">
                <span :if={item.ticker.last_price} class="tabular-nums text-sm opacity-70">
                  ${item.ticker.last_price}
                </span>

                <button
                  type="button"
                  phx-click="remove_ticker"
                  phx-value-id={item.id}
                  data-confirm="Remove from watchlist?"
                  class="btn btn-ghost btn-xs text-error"
                >
                  Remove
                </button>
              </div>
            </li>
          </ul>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
