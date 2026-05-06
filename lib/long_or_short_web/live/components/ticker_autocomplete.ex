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

  ## `wrap_in_form`

  When `true` (default) the input is wrapped in its own `<form>` tag.
  Set to `false` when nesting the component inside a parent `<form>`
  (HTML disallows nested forms — the browser silently closes the outer
  form when it sees the inner one). In that mode `phx-change` is bound
  directly to the input, which Phoenix LiveView allows as long as the
  input lives inside *some* form.

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
  attr :wrap_in_form, :boolean, default: true

  def ticker_autocomplete(assigns) do
    ~H"""
    <div>
      <.ticker_input
        query={@query}
        search_event={@search_event}
        clear_event={@clear_event}
        wrap_in_form={@wrap_in_form}
      />

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

  attr :query, :string, required: true
  attr :search_event, :string, required: true
  attr :clear_event, :string, required: true
  attr :wrap_in_form, :boolean, required: true

  defp ticker_input(%{wrap_in_form: true} = assigns) do
    ~H"""
    <form phx-change={@search_event} phx-submit={@search_event} autocomplete="off">
      <.ticker_input_inner
        query={@query}
        clear_event={@clear_event}
        phx_change={nil}
      />
    </form>
    """
  end

  defp ticker_input(%{wrap_in_form: false} = assigns) do
    ~H"""
    <.ticker_input_inner
      query={@query}
      clear_event={@clear_event}
      phx_change={@search_event}
    />
    """
  end

  attr :query, :string, required: true
  attr :clear_event, :string, required: true
  attr :phx_change, :any, required: true

  defp ticker_input_inner(assigns) do
    ~H"""
    <div class="relative">
      <input
        type="text"
        name="query"
        value={@query}
        placeholder="Symbol or company"
        phx-change={@phx_change}
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
    """
  end
end
