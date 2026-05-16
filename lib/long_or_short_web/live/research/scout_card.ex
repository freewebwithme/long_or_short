defmodule LongOrShortWeb.Live.Research.ScoutCard do
  @moduledoc """
  Function components for the Scout surface (LON-173).

  "Scout" is the user-facing brand for the Pre-Trade Briefing flow;
  the internal data type stays `LongOrShort.Research.TickerBriefing`
  (LON-172). Surface-name vs. data-noun split deliberately preserved.

  Mirrors `LongOrShortWeb.Live.MorningBrief.BriefCard` patterns for
  citation rendering + markdown body so both surfaces feel consistent
  to the reader.

  ## Components

    * `scout_result_card/1` — full briefing display (narrative +
      citations + meta header)
    * `scout_status_bar/1` — spinner + elapsed timer + rotating
      soft progress message during a `:running` generation
    * `scout_empty_state/1` — `/scout` index landing state
    * `scout_no_profile_state/1` — gated for users without a
      `TradingProfile` (LON-102 pattern)
    * `recent_scouts_panel/1` — right-side history list with
      keyset pagination

  ## Status state machine (driven by `ScoutLive`)

    * `:idle` — no ticker locked yet (`/scout` route)
    * `:ready` — ticker locked, no fresh briefing, Run button active
    * `:running` — Oban job in flight, status bar shows
    * `:done` — fresh briefing available, result card shows
    * `:error` — generation failed, retry CTA shows
  """

  use Phoenix.Component
  use LongOrShortWeb, :verified_routes

  import LongOrShortWeb.CoreComponents, only: [icon: 1]

  alias Phoenix.HTML

  # ── Main result card ─────────────────────────────────────────────

  attr :briefing, :any,
    required: true,
    doc: "The `TickerBriefing` row to render."

  def scout_result_card(assigns) do
    ~H"""
    <section
      id={"scout-result-#{@briefing.id}"}
      class="card bg-base-200 border border-base-300 p-4"
    >
      <.result_header briefing={@briefing} />
      <article class="briefing-prose max-w-none">
        {render_markdown(@briefing.narrative)}
      </article>
      <.citations_section citations={@briefing.citations} />
    </section>
    """
  end

  attr :briefing, :any, required: true

  defp result_header(assigns) do
    ~H"""
    <div class="text-xs opacity-60 mb-3 flex items-center gap-2 flex-wrap">
      <span class="font-semibold text-base">{@briefing.symbol}</span>
      <span>·</span>
      <span title={DateTime.to_string(@briefing.generated_at)}>
        {time_since(@briefing.generated_at)}
      </span>
      <span>·</span>
      <span class="opacity-70">{@briefing.model}</span>
      <span :if={fresh?(@briefing)} class="badge badge-success badge-sm ml-auto">fresh</span>
      <span :if={!fresh?(@briefing)} class="badge badge-warning badge-sm ml-auto">stale</span>
    </div>
    """
  end

  # ── Status bar (running state) ───────────────────────────────────

  attr :elapsed_seconds, :integer,
    required: true,
    doc: "Seconds since the worker was enqueued — drives the displayed timer."

  attr :symbol, :string, required: true

  def scout_status_bar(assigns) do
    assigns = assign(assigns, :rotating_message, rotating_message(assigns.elapsed_seconds))

    ~H"""
    <section
      id="scout-status-bar"
      class="card bg-base-200 border border-base-300 p-4"
    >
      <div class="flex items-center gap-3">
        <span class="loading loading-spinner loading-md text-primary" aria-hidden="true" />
        <div class="flex-1">
          <div class="font-semibold text-sm">Scouting {@symbol}…</div>
          <div class="text-xs opacity-70">
            {@rotating_message} · <strong>{format_elapsed(@elapsed_seconds)}</strong> elapsed
          </div>
        </div>
      </div>
      <p class="text-xs opacity-50 mt-3">
        Briefings usually take 5–15 seconds. Web search results + analysis are pulled live.
      </p>
    </section>
    """
  end

  # Rotates through plausible progress messages keyed off elapsed
  # time. NOT tied to actual provider stream — Anthropic
  # `call_with_search/2` is synchronous, no progress events. PT-3/4
  # may revisit if streaming lands.
  defp rotating_message(seconds) when seconds < 3, do: "Pulling SEC filings"
  defp rotating_message(seconds) when seconds < 7, do: "Searching news (last 24h)"
  defp rotating_message(seconds) when seconds < 12, do: "Synthesizing risks + sentiment"
  defp rotating_message(_), do: "Almost done — drafting the briefing"

  defp format_elapsed(s) when s < 60, do: "#{s}s"
  defp format_elapsed(s), do: "#{div(s, 60)}m #{rem(s, 60)}s"

  # ── Empty + gated states ─────────────────────────────────────────

  def scout_empty_state(assigns) do
    ~H"""
    <section class="card bg-base-200 border border-base-300 p-6 text-center">
      <.icon name="hero-magnifying-glass" class="size-8 mx-auto opacity-50" />
      <h2 class="font-semibold mt-2 mb-1">Pick a ticker to scout</h2>
      <p class="text-xs opacity-70">
        Use the search box on the left. Once you pick a symbol, the Run Scout button
        will appear — briefings are generated only when you ask.
      </p>
    </section>
    """
  end

  attr :symbol, :string, required: true

  def scout_ready_state(assigns) do
    ~H"""
    <section class="card bg-base-200 border border-base-300 p-6 text-center">
      <p class="opacity-70 mb-3">
        No cached briefing for <strong>{@symbol}</strong>.
      </p>
      <p class="text-xs opacity-50">
        Click <strong>Run Scout</strong> above to generate one. Briefings are
        cached for ~10 minutes after generation.
      </p>
    </section>
    """
  end

  def scout_no_profile_state(assigns) do
    ~H"""
    <section class="alert alert-warning text-sm">
      <.icon name="hero-exclamation-triangle" class="size-5 shrink-0" />
      <div>
        <p class="font-semibold mb-1">Setup your trader profile first</p>
        <p class="text-xs opacity-80">
          Scout briefings inject your trading style (momentum_day, swing, etc.) into
          the AI prompt. Add a profile at
          <.link navigate={~p"/profile"} class="link link-hover font-semibold">/profile</.link>
          to enable Scout.
        </p>
      </div>
    </section>
    """
  end

  attr :symbol, :string, required: true
  attr :reason, :any, required: true

  def scout_error_state(assigns) do
    ~H"""
    <section class="alert alert-error text-sm">
      <.icon name="hero-x-circle" class="size-5 shrink-0" />
      <div class="flex-1">
        <p class="font-semibold mb-1">Scout for {@symbol} failed</p>
        <p class="text-xs opacity-80">{format_reason(@reason)}</p>
      </div>
      <button
        type="button"
        class="btn btn-sm btn-outline"
        phx-click="run_scout"
      >
        Retry
      </button>
    </section>
    """
  end

  defp format_reason(:unknown_symbol), do: "Ticker not found in our universe."
  defp format_reason(:no_trading_profile), do: "Trader profile required — set one up at /profile."
  defp format_reason({:rate_limited, _}), do: "AI provider rate limit hit. Try again in a minute."
  defp format_reason(reason), do: inspect(reason)

  # ── Recent scouts panel (right side) ─────────────────────────────

  attr :briefings, :list, required: true
  attr :more?, :boolean, default: false
  attr :prev_cursor, :any, default: nil
  attr :next_cursor, :any, default: nil

  def recent_scouts_panel(assigns) do
    ~H"""
    <aside id="recent-scouts-panel" class="card bg-base-200 border border-base-300 p-4 h-full">
      <h2 class="text-sm font-semibold mb-3 flex items-center gap-2">
        <.icon name="hero-clock" class="size-4 opacity-60" /> Recent scouts
      </h2>

      <div :if={@briefings == []} class="text-xs opacity-60 italic">
        No scouts yet — run one on the left to see it land here.
      </div>

      <ul :if={@briefings != []} class="space-y-1.5">
        <li :for={b <- @briefings}>
          <.link
            navigate={~p"/scout/b/#{b.id}"}
            class="block hover:bg-base-300/50 rounded px-2 py-1.5 transition"
          >
            <div class="flex items-baseline gap-2">
              <span class="font-mono font-semibold text-sm">{b.symbol}</span>
              <span class="text-xs opacity-50">{time_since(b.generated_at)}</span>
            </div>
            <div class="text-xs opacity-60 truncate">{first_line(b.narrative)}</div>
          </.link>
        </li>
      </ul>

      <.pagination_controls
        :if={@briefings != [] and (@prev_cursor != nil or @more?)}
        prev_cursor={@prev_cursor}
        next_cursor={@next_cursor}
        more?={@more?}
      />
    </aside>
    """
  end

  attr :prev_cursor, :any, required: true
  attr :next_cursor, :any, required: true
  attr :more?, :boolean, required: true

  defp pagination_controls(assigns) do
    ~H"""
    <div class="flex justify-between items-center mt-3 pt-3 border-t border-base-300">
      <button
        type="button"
        class={[
          "btn btn-xs btn-ghost",
          @prev_cursor == nil && "btn-disabled opacity-30"
        ]}
        phx-click="prev_page"
        disabled={@prev_cursor == nil}
      >
        <.icon name="hero-chevron-left" class="size-3" /> Prev
      </button>
      <button
        type="button"
        class={[
          "btn btn-xs btn-ghost",
          not @more? && "btn-disabled opacity-30"
        ]}
        phx-click="next_page"
        disabled={not @more?}
      >
        Next <.icon name="hero-chevron-right" class="size-3" />
      </button>
    </div>
    """
  end

  # ── Dashboard widget ─────────────────────────────────────────────

  attr :briefings, :list, required: true

  def recent_scouts_widget(assigns) do
    ~H"""
    <div class="card bg-base-200 border border-base-300 p-4">
      <div class="flex items-center justify-between mb-3">
        <h2 class="text-sm font-semibold flex items-center gap-2">
          <.icon name="hero-magnifying-glass" class="size-4 opacity-60" /> Recent scouts
        </h2>
        <.link navigate={~p"/scout"} class="link link-hover text-xs opacity-70">
          All →
        </.link>
      </div>

      <div :if={@briefings == []} class="text-xs opacity-60 italic">
        No scouts yet — <.link navigate={~p"/scout"} class="link link-hover">
          run one
        </.link>.
      </div>

      <ul :if={@briefings != []} class="space-y-1">
        <li :for={b <- @briefings}>
          <.link
            navigate={~p"/scout/b/#{b.id}"}
            class="flex items-baseline justify-between hover:bg-base-300/50 rounded px-2 py-1 transition"
          >
            <span class="font-mono font-semibold text-sm">{b.symbol}</span>
            <span class="text-xs opacity-50">{time_since(b.generated_at)}</span>
          </.link>
        </li>
      </ul>
    </div>
    """
  end

  # ── Shared helpers ───────────────────────────────────────────────

  attr :citations, :list, required: true

  defp citations_section(assigns) do
    ~H"""
    <section
      :if={@citations != []}
      class="mt-4 pt-3 border-t border-base-300"
    >
      <h3 class="text-xs font-semibold opacity-60 mb-2">Sources</h3>
      <ol class="text-xs space-y-1.5">
        <li :for={c <- @citations} class="flex gap-2">
          <span class="opacity-60 shrink-0 w-6">[{cget(c, :idx)}]</span>
          <a
            href={cget(c, :url)}
            target="_blank"
            rel="noopener noreferrer"
            onclick="return confirm('외부 링크로 이동합니다. 계속하시겠습니까?')"
            class="link link-hover truncate"
          >
            <span :if={cget(c, :source)} class="opacity-70">{cget(c, :source)}</span>
            <span :if={cget(c, :source)} class="opacity-50">—</span>
            {cget(c, :title)}
          </a>
        </li>
      </ol>
    </section>
    """
  end

  defp render_markdown(content) when is_binary(content) do
    content |> MDEx.to_html!() |> HTML.raw()
  end

  defp render_markdown(_), do: HTML.raw("")

  defp fresh?(%{cached_until: %DateTime{} = cu}),
    do: DateTime.compare(cu, DateTime.utc_now()) == :gt

  defp fresh?(_), do: false

  defp first_line(content) when is_binary(content) do
    content
    |> String.split("\n", parts: 2)
    |> List.first()
    |> String.replace(~r/^#+\s*/, "")
    |> String.slice(0, 80)
  end

  defp first_line(_), do: ""

  defp cget(map, key) when is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp time_since(%DateTime{} = dt) do
    seconds = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      seconds < 60 -> "just now"
      seconds < 3_600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3_600)}h ago"
      true -> "#{div(seconds, 86_400)}d ago"
    end
  end

  defp time_since(_), do: ""
end
