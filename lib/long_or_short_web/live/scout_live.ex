defmodule LongOrShortWeb.ScoutLive do
  @moduledoc """
  Pre-Trade Briefing surface — on-demand single-ticker research
  ("Scout" — LON-173, PT-2 of [[LON-171]]).

  ## Routes

    * `/scout` — index, no symbol locked, autocomplete + history
    * `/scout/:symbol` — symbol locked, cache hit renders immediately
      or Run button awaits user action

  Both routes mount the same LiveView; `handle_params/3` switches
  state machine entry based on `live_action`.

  ## State machine

      :idle      ── /scout (no symbol)
      :ready     ── ticker locked, no fresh cache
      :running   ── Oban job in flight, status bar
      :done      ── fresh briefing assigned
      :error     ── failed, retry CTA

  See `LongOrShortWeb.Live.Research.ScoutCard` for the visual layer.

  ## Async path

  `LongOrShort.Research.Workers.BriefingWorker` (LON-172) does the
  generation; this LiveView subscribes to
  `Research.Events.subscribe_for_user/1` on mount and routes
  `:briefing_started | :briefing_ready | :briefing_failed` payloads
  by `request_id` correlation.

  ## Mid-run ticker switch

  A user may patch from `/scout/AAPL` to `/scout/NVDA` while AAPL's
  briefing is still generating. Both jobs run to completion; the
  AAPL result is ignored here when it arrives (mismatch on
  `request_id`), but it still lands in the DB and on the recent
  scouts list. The current view tracks only the **active**
  request_id — everything else is dropped.
  """

  use LongOrShortWeb, :live_view

  alias LongOrShort.Research
  alias LongOrShort.Research.Events, as: ResearchEvents
  alias LongOrShort.Research.TickerBriefing
  alias LongOrShort.Research.Workers.BriefingWorker
  alias LongOrShort.Tickers
  alias LongOrShortWeb.Live.Components.TickerAutocomplete
  alias LongOrShortWeb.Live.Research.ScoutCard

  @history_page_size 10
  @tick_interval_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      ResearchEvents.subscribe_for_user(socket.assigns.current_user.id)
    end

    {:ok,
     socket
     |> assign(:status, :idle)
     |> assign(:locked_symbol, nil)
     |> assign(:briefing, nil)
     |> assign(:active_request_id, nil)
     |> assign(:elapsed_seconds, 0)
     |> assign(:error_reason, nil)
     |> assign(:ticker_query, "")
     |> assign(:ticker_results, [])
     |> assign(:history_results, [])
     |> assign(:history_more?, false)
     |> assign(:history_cursors, [])
     |> assign(:page_title, "Scout")
     |> load_history()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case socket.assigns.live_action do
      :index ->
        {:noreply, reset_to_idle(socket)}

      :show ->
        {:noreply, lock_symbol(socket, String.upcase(params["symbol"]))}
    end
  end

  # ── Events ──────────────────────────────────────────────────────

  @impl true
  def handle_event("ticker_filter_search", %{"query" => query}, socket) do
    trimmed = String.trim(query)

    results =
      if trimmed == "" do
        []
      else
        case Tickers.search_tickers(trimmed, actor: socket.assigns.current_user) do
          {:ok, list} -> list
          _ -> []
        end
      end

    {:noreply,
     socket
     |> assign(:ticker_query, trimmed)
     |> assign(:ticker_results, results)}
  end

  def handle_event("ticker_filter_select", %{"symbol" => symbol}, socket) do
    {:noreply, push_patch(socket, to: ~p"/scout/#{String.upcase(symbol)}")}
  end

  def handle_event("ticker_filter_clear", _, socket) do
    {:noreply, push_patch(socket, to: ~p"/scout")}
  end

  def handle_event("run_scout", _, socket) do
    {:noreply, start_briefing(socket, [])}
  end

  # LON-174: force-refresh CTA on the result card. Same flow as run_scout
  # but bypasses the DB cache via `force: true`. Server-side 60s rate
  # limit (`BriefingGenerator`) catches abusive clicks; the failure
  # broadcast surfaces as `:rate_limited_refresh` in the `:error` state.
  def handle_event("refresh_scout", _, socket) do
    {:noreply, start_briefing(socket, force: true)}
  end

  def handle_event("next_page", _, socket) do
    case socket.assigns.history_results do
      [] -> {:noreply, socket}
      _ -> {:noreply, load_history(socket, :forward)}
    end
  end

  def handle_event("prev_page", _, socket) do
    {:noreply, load_history(socket, :backward)}
  end

  # ── PubSub callbacks ────────────────────────────────────────────

  @impl true
  def handle_info({:briefing_started, _ticker_id, request_id}, socket) do
    # Started broadcast is informational; the worker has picked up the
    # job. We're already in `:running`. Filter by request_id so a
    # parallel briefing for a different ticker doesn't poke us.
    if request_id == socket.assigns.active_request_id do
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:briefing_ready, _ticker_id, briefing_id, request_id}, socket) do
    cond do
      request_id == socket.assigns.active_request_id ->
        case Research.get_ticker_briefing(briefing_id,
               actor: socket.assigns.current_user
             ) do
          {:ok, briefing} ->
            {:noreply,
             socket
             |> assign(:status, :done)
             |> assign(:briefing, briefing)
             |> assign(:active_request_id, nil)
             |> load_history()}

          _ ->
            {:noreply,
             socket
             |> assign(:status, :error)
             |> assign(:error_reason, :briefing_load_failed)
             |> assign(:active_request_id, nil)}
        end

      true ->
        # A briefing for another ticker (user switched mid-run) — keep
        # current view, just refresh history so the new row shows up.
        {:noreply, load_history(socket)}
    end
  end

  def handle_info({:briefing_failed, _ticker_id, reason, request_id}, socket) do
    if request_id == socket.assigns.active_request_id do
      {:noreply,
       socket
       |> assign(:status, :error)
       |> assign(:error_reason, reason)
       |> assign(:active_request_id, nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:tick, socket) do
    case socket.assigns.status do
      :running ->
        schedule_tick()
        {:noreply, assign(socket, :elapsed_seconds, socket.assigns.elapsed_seconds + 1)}

      _ ->
        {:noreply, socket}
    end
  end

  # ── Render ──────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app current_path={@current_path} current_user={@current_user} flash={@flash}>
      <div class="grid grid-cols-1 lg:grid-cols-[1fr_320px] gap-4">
        <!-- LEFT: search → button → status → result -->
        <div class="space-y-4">
          <div id="scout-search">
            <TickerAutocomplete.ticker_autocomplete
              query={@ticker_query}
              results={@ticker_results}
              search_event="ticker_filter_search"
              select_event="ticker_filter_select"
              clear_event="ticker_filter_clear"
            />
          </div>

          <div :if={@locked_symbol} class="flex items-center gap-3">
            <span class="text-sm opacity-70">
              Selected: <strong class="font-mono">{@locked_symbol}</strong>
            </span>
            <button
              type="button"
              phx-click="run_scout"
              class="btn btn-primary btn-sm"
              disabled={@status == :running or is_nil(@current_user.trading_profile)}
            >
              <span :if={@status == :running} class="loading loading-spinner loading-xs" />
              {if @status == :running, do: "Scouting…", else: "Run Scout"}
            </button>
          </div>

          <ScoutCard.scout_no_profile_state :if={
            @locked_symbol && is_nil(@current_user.trading_profile)
          } />
          
    <!-- State-machine driven body -->
          <%= case @status do %>
            <% :idle -> %>
              <ScoutCard.scout_empty_state />
            <% :ready -> %>
              <ScoutCard.scout_ready_state symbol={@locked_symbol} />
            <% :running -> %>
              <ScoutCard.scout_status_bar
                symbol={@locked_symbol}
                elapsed_seconds={@elapsed_seconds}
              />
            <% :done -> %>
              <ScoutCard.scout_result_card briefing={@briefing} />
            <% :error -> %>
              <ScoutCard.scout_error_state
                symbol={@locked_symbol || "—"}
                reason={@error_reason}
              />
          <% end %>
        </div>
        
    <!-- RIGHT: history panel -->
        <ScoutCard.recent_scouts_panel
          briefings={@history_results}
          more?={@history_more?}
          prev_cursor={prev_cursor(@history_cursors)}
          next_cursor={if @history_more?, do: :next, else: nil}
        />
      </div>
    </Layouts.app>
    """
  end

  # ── Helpers ─────────────────────────────────────────────────────

  # Shared start path for `run_scout` (fresh) and `refresh_scout`
  # (force=true). Guards a missing `locked_symbol` and a missing
  # `trading_profile` before enqueueing. Extracted on the 2nd
  # occurrence to keep both event handlers tiny.
  defp start_briefing(%{assigns: %{locked_symbol: nil}} = socket, _opts), do: socket

  defp start_briefing(socket, generator_opts) do
    cond do
      is_nil(socket.assigns.current_user.trading_profile) ->
        socket
        |> assign(:status, :error)
        |> assign(:error_reason, :no_trading_profile)

      true ->
        {request_id, _job_result} =
          BriefingWorker.enqueue(
            socket.assigns.locked_symbol,
            socket.assigns.current_user.id,
            generator_opts: generator_opts
          )

        schedule_tick()

        socket
        |> assign(:status, :running)
        |> assign(:active_request_id, request_id)
        |> assign(:elapsed_seconds, 0)
        |> assign(:error_reason, nil)
    end
  end

  defp reset_to_idle(socket) do
    socket
    |> assign(:status, :idle)
    |> assign(:locked_symbol, nil)
    |> assign(:briefing, nil)
    |> assign(:active_request_id, nil)
    |> assign(:elapsed_seconds, 0)
    |> assign(:error_reason, nil)
    |> assign(:ticker_query, "")
    |> assign(:ticker_results, [])
  end

  defp lock_symbol(socket, symbol) do
    user = socket.assigns.current_user

    case Research.get_latest_briefing_for(symbol, user.id, actor: user) do
      {:ok, %TickerBriefing{} = briefing} ->
        socket
        |> assign(:status, :done)
        |> assign(:locked_symbol, symbol)
        |> assign(:briefing, briefing)
        |> assign(:active_request_id, nil)
        |> assign(:error_reason, nil)
        |> assign(:ticker_query, symbol)
        |> assign(:ticker_results, [])
        |> assign(:page_title, "Scout · #{symbol}")

      _ ->
        socket
        |> assign(:status, :ready)
        |> assign(:locked_symbol, symbol)
        |> assign(:briefing, nil)
        |> assign(:active_request_id, nil)
        |> assign(:error_reason, nil)
        |> assign(:ticker_query, symbol)
        |> assign(:ticker_results, [])
        |> assign(:page_title, "Scout · #{symbol}")
    end
  end

  defp load_history(socket, direction \\ :reset) do
    user = socket.assigns.current_user
    page_opts = build_page_opts(socket, direction)

    case Research.list_recent_briefings_by_user(user.id,
           actor: user,
           page: page_opts
         ) do
      {:ok, %Ash.Page.Keyset{results: results, more?: more?}} ->
        cursors = update_cursors(socket.assigns.history_cursors || [], direction, results)

        socket
        |> assign(:history_results, results)
        |> assign(:history_more?, more?)
        |> assign(:history_cursors, cursors)

      _ ->
        socket
        |> assign(:history_results, [])
        |> assign(:history_more?, false)
        |> assign(:history_cursors, [])
    end
  end

  defp build_page_opts(_socket, :reset),
    do: [limit: @history_page_size]

  defp build_page_opts(socket, :forward) do
    case List.last(socket.assigns.history_results || []) do
      %{__metadata__: %{keyset: cursor}} ->
        [limit: @history_page_size, after: cursor]

      _ ->
        [limit: @history_page_size]
    end
  end

  defp build_page_opts(socket, :backward) do
    case socket.assigns.history_cursors do
      [_current | [prev | _]] -> [limit: @history_page_size, before: prev]
      _ -> [limit: @history_page_size]
    end
  end

  # Keep a stack of "first row's keyset" per page for Prev navigation.
  # `:reset` clears, `:forward` pushes the new top, `:backward` pops.
  defp update_cursors(_stack, :reset, results), do: [first_keyset(results)]

  defp update_cursors(stack, :forward, results),
    do: [first_keyset(results) | stack]

  defp update_cursors([_top | rest], :backward, _), do: rest
  defp update_cursors(stack, :backward, _), do: stack

  defp first_keyset([%{__metadata__: %{keyset: cursor}} | _]), do: cursor
  defp first_keyset(_), do: nil

  defp prev_cursor([_only_current]), do: nil
  defp prev_cursor([_current | [_prev | _]]), do: :prev
  defp prev_cursor(_), do: nil

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_interval_ms)
end
