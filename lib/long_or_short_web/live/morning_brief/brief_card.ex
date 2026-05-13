defmodule LongOrShortWeb.Live.MorningBrief.BriefCard do
  @moduledoc """
  Function components for the Morning Brief card surface (LON-152).

  Renders the `MorningBriefDigest` produced by the LON-151 cron pipeline
  as a single card at the top of `MorningBriefLive`:

    * `brief_card/1` — outer container, dispatches on status
    * `bucket_tabs/1` — overnight / premarket / after_open selector
    * `freshness_indicator/1` — relative-time label ("12m ago") + bucket date
    * `citations_section/1` — Sources list with external-link confirm
    * `stale_banner/1` — gray "오늘 브리프 미준비" notice + fallback
    * `empty_state/1` — "곧 준비됩니다" zero-cache state

  ## Status semantics (driven by `MorningBriefLive.load_brief/3`)

    * `:fresh` — today's date + selected bucket has a Digest
    * `:stale` — no today's row but a previous one is cached
    * `:empty` — no Digest exists at all (cold start)

  No refresh button, cooldown countdown, or daily-limit UI — cron is
  the only trigger (LON-147 design decision).
  """

  use Phoenix.Component
  use LongOrShortWeb, :verified_routes

  import LongOrShortWeb.CoreComponents, only: [icon: 1]

  alias Phoenix.HTML

  @bucket_options [
    {:overnight, "Overnight"},
    {:premarket, "Premarket"},
    {:after_open, "After Open"}
  ]

  @doc """
  Outer brief-card container. Renders different inner content based
  on `:status`. Always renders the bucket tabs so the user can switch
  even in `:stale` / `:empty` states.
  """
  attr :status, :atom, required: true, values: [:fresh, :stale, :empty]
  attr :digest, :any, default: nil
  attr :bucket, :atom, required: true

  def brief_card(assigns) do
    ~H"""
    <section
      id="morning-brief-card"
      class="card bg-base-200 border border-base-300 p-4 mb-6"
    >
      <.bucket_tabs current={@bucket} />

      <%= case @status do %>
        <% :fresh -> %>
          <.freshness_indicator digest={@digest} stale?={false} />
          <.brief_body digest={@digest} />
        <% :stale -> %>
          <.stale_banner digest={@digest} bucket={@bucket} />
          <.freshness_indicator digest={@digest} stale?={true} />
          <.brief_body digest={@digest} />
        <% :empty -> %>
          <.empty_state bucket={@bucket} />
      <% end %>
    </section>
    """
  end

  @doc """
  Three-tab selector that fires `phx-click="select_bucket"` on the
  parent LiveView. The current bucket is highlighted; the others
  switch the active Digest fetch.
  """
  attr :current, :atom, required: true

  def bucket_tabs(assigns) do
    assigns = assign(assigns, :options, @bucket_options)

    ~H"""
    <div class="join mb-3" id="morning-brief-buckets">
      <button
        :for={{bucket, label} <- @options}
        type="button"
        phx-click="select_bucket"
        phx-value-bucket={Atom.to_string(bucket)}
        class={[
          "btn btn-sm join-item",
          if(@current == bucket, do: "btn-primary", else: "btn-ghost")
        ]}
      >
        {label}
      </button>
    </div>
    """
  end

  attr :digest, :any, required: true
  attr :stale?, :boolean, default: false

  def freshness_indicator(assigns) do
    ~H"""
    <div class="text-xs opacity-60 mb-3 flex items-center gap-2 flex-wrap">
      <span class="font-semibold">{bucket_display(@digest.bucket)}</span>
      <span>·</span>
      <span>{Date.to_string(@digest.bucket_date)}</span>
      <span>·</span>
      <span>{time_since(@digest.generated_at)}</span>
      <span :if={@stale?} class="badge badge-warning badge-sm">stale</span>
    </div>
    """
  end

  attr :citations, :list, required: true

  def citations_section(assigns) do
    ~H"""
    <section
      :if={@citations != []}
      id="morning-brief-citations"
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
            <span class="opacity-70">{cget(c, :source)}</span>
            <span class="opacity-50">—</span>
            {cget(c, :title)}
          </a>
        </li>
      </ol>
    </section>
    """
  end

  attr :digest, :any, required: true
  attr :bucket, :atom, required: true

  def stale_banner(assigns) do
    ~H"""
    <div class="alert alert-warning text-xs mb-3">
      <.icon name="hero-clock" class="size-4 shrink-0" />
      <span>
        Today's <strong>{bucket_display(@bucket)}</strong>
        brief isn't ready yet — scheduled for {bucket_eta(@bucket)}.
        (Last cached: {Date.to_string(@digest.bucket_date)} {bucket_display(@digest.bucket)})
      </span>
    </div>
    """
  end

  attr :bucket, :atom, required: true

  def empty_state(assigns) do
    ~H"""
    <div class="text-center py-8 opacity-70">
      <p class="mb-2">📰 Brief is on the way.</p>
      <p class="text-xs opacity-80">
        Briefs are generated daily at 05:00 / 08:45 / 10:15 ET.
        Check the article list below for the latest news.
      </p>
    </div>
    """
  end

  # ── Inner body (markdown + citations) ────────────────────────────

  attr :digest, :any, required: true

  defp brief_body(assigns) do
    ~H"""
    <article class="prose prose-sm max-w-none">
      {render_markdown(@digest.content)}
    </article>
    <.citations_section citations={@digest.citations} />
    """
  end

  # ── Helpers ──────────────────────────────────────────────────────

  # MDEx renders markdown → HTML; raw HTML in the source is escaped by
  # default (we pass nothing to `:render` or `:sanitize`). LLM output
  # is mostly headers/paragraphs/bold/lists — safe defaults are
  # appropriate, no `unsafe: true` here.
  defp render_markdown(content) when is_binary(content) do
    content |> MDEx.to_html!() |> HTML.raw()
  end

  defp render_markdown(_), do: HTML.raw("")

  defp bucket_display(:overnight), do: "Overnight"
  defp bucket_display(:premarket), do: "Premarket"
  defp bucket_display(:after_open), do: "After Open"

  # Bucket → user-facing ETA copy. Mirrors the schedule in
  # `LongOrShort.MorningBrief.CronWorker` (05:00 / 08:45 / 10:15 ET).
  defp bucket_eta(:overnight), do: "5:00 ET"
  defp bucket_eta(:premarket), do: "8:45 ET"
  defp bucket_eta(:after_open), do: "10:15 ET"

  # Citations come from a jsonb column → string keys after Jason
  # round-trip on read. Tests/fixtures may pass atom keys. Try atom
  # first, fall back to string. Covers both shapes without a
  # per-field dual-clause explosion.
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
      seconds < 3600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3600)}h ago"
      true -> "#{div(seconds, 86_400)}d ago"
    end
  end
end
