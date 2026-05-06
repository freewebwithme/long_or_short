defmodule LongOrShortWeb.Live.Components.TickerAutocomplete do
  @moduledoc """
  Shared ticker search + autocomplete function component.

  Renders a text input with debounce, a clear button, a suggestion
  list, and a "no matches" hint. All state (query, results) lives in
  the host LiveView; this component only handles markup.

  Events fired (all to the host LiveView, not to this component):

    * `search_event`  — phx-change on the input, payload `%{"query" => ...}`
    * `select_event`  — phx-click on a suggestion, payload `%{"symbol" => ...}`
    * `clear_event`   — phx-click on the × button, no payload

  Usage example:

      <TickerAutocomplete.ticker_autocomplete
        query={@ticker_query}
        results={@ticker_results}
        search_event="ticker_search"
        select_event="ticker_selected"
        clear_event="ticker_clear"
      />
  """

  use Phoenix.Component
  use LongOrShortWeb, :verified_routes

  import LongOrShortWeb.CoreComponents, only: [icon: 1]

  attr :query, :string, required: true
  attr :results, :list, required: true
  attr :search_event, :string, default: "search"
  attr :select_event, :string, default: "select_ticker"
  attr :clear_event, :string, default: "clear_search"

  def ticker_autocomplete(assigns) do
    ~H"""
    <div>
      <form phx-change={@search_event} phx-submit={@search_event} autocomplete="off">
        <div class="relative">
          <input
            type="text"
            name="query"
            value={@query}
            placeholder="Symbol or company"
            phx-debounce="200"
            class="input input-sm input-bordered w-full pr-8"
          />
          <button
            :if={@query != ""}
            type="button"
            phx-click={@clear_event}
            class="absolute right-1 top-1 btn btn-ghost btn-xs btn-circle"
            aria-label="Clear search"
          >
            <.icon name="hero-x-mark" class="size-3" />
          </button>
        </div>
      </form>

      <ul :if={@results != []} class="mt-2 divide-y divide-base-300 text-sm">
        <li :for={ticker <- @results}>
          <button
            type="button"
            phx-click={@select_event}
            phx-value-symbol={ticker.symbol}
            class="w-full text-left p-2 hover:bg-base-300 rounded"
          >
            <div class="font-bold">{ticker.symbol}</div>
            <div :if={ticker.company_name} class="text-xs opacity-60 truncate">
              {ticker.company_name}
            </div>
          </button>
        </li>
      </ul>

      <div :if={@query != "" && @results == []} class="text-xs opacity-60 mt-2 italic">
        No matches
      </div>
    </div>
    """
  end
end
