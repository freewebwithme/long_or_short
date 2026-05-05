defmodule LongOrShortWeb.Live.Components.NewsComponents do
  @moduledoc """
  HEEx components for rendering a `NewsAnalysis` on trader-facing
  surfaces (`/feed`, `/analyze`, future ticker drilldown).

  Three pieces, all function components:

    * `news_pill/1` — one coloured pill (signal axis + value)
    * `news_card/1` — compact 6-pill block + `headline_takeaway` + Detail toggle
    * `news_detail/1` — expanded 5-section Markdown view (rendered via MDEx)

  Pill colour mapping is per LON-83. Phase 1 stub fields
  (`:insufficient_data`, `:partial`) carry a dashed border + tooltip so
  the trader sees which signals aren't yet driven by real data.
  """
  use Phoenix.Component
  use LongOrShortWeb, :verified_routes

  alias LongOrShort.Analysis.NewsAnalysis

  # ── news_card ────────────────────────────────────────────────────────
  @doc """
  Compact 6-signal block shown beneath an article.

  ## Attrs
    * `:analysis` — `%NewsAnalysis{}`, required
    * `:expanded?` — whether the Detail view is open (parent owns this)
  """
  attr :analysis, NewsAnalysis, required: true
  attr :expanded?, :boolean, default: false

  def news_card(assigns) do
    ~H"""
    <div class="mt-3 pt-3 border-t border-base-300 space-y-2">
      <div class="flex flex-wrap gap-1.5">
        <.news_pill
          emoji="💪"
          label="Strength"
          value={@analysis.catalyst_strength}
          field={:catalyst_strength}
        />
        <.news_pill emoji="🏷️ " value={@analysis.catalyst_type} field={:catalyst_type} />
        <.news_pill emoji="💭" value={@analysis.sentiment} field={:sentiment} />
        <.news_pill
          emoji="⚠️ "
          label="Pump-fade"
          value={@analysis.pump_fade_risk}
          field={:pump_fade_risk}
        />
        <.news_pill
          emoji="🔁"
          label="Repetition"
          value={"#{@analysis.repetition_count}×"}
          field={:repetition}
        />
        <.news_pill
          emoji="🎯"
          label="Strategy"
          value={@analysis.strategy_match}
          field={:strategy_match}
        />
        <.news_pill emoji="🚦" value={@analysis.verdict} field={:verdict} bold />
      </div>

      <p :if={@analysis.headline_takeaway} class="text-sm italic opacity-80">
        "{@analysis.headline_takeaway}"
      </p>

      <button
        type="button"
        phx-click="toggle_detail"
        phx-value-id={@analysis.article_id}
        class="text-xs opacity-60 hover:opacity-100 inline-flex items-center gap-1"
      >
        {if @expanded?, do: "▲ Hide detail", else: "▼ Detail view"}
      </button>
    </div>
    """
  end

  # ── news_pill ────────────────────────────────────────────────────────

  @doc """
  A single coloured pill for one signal. Colour and (optional) dashed
  border come from the `(field, value)` mapping below.
  """
  attr :emoji, :string, default: nil
  attr :label, :string, default: ""
  attr :value, :any, required: true
  attr :field, :atom, required: true
  attr :bold, :boolean, default: false

  def news_pill(assigns) do
    {colour, dashed?} = pill_style(assigns.field, assigns.value)

    assigns =
      assigns
      |> assign(:colour, colour)
      |> assign(:dashed?, dashed?)

    ~H"""
    <span
      class={[
        "inline-flex items-center gap-1 px-2 py-0.5 rounded text-xs",
        @colour,
        @dashed? && "border border-dashed",
        @bold && "font-bold"
      ]}
      title={pill_tooltip(@field, @value)}
    >
      <span :if={@emoji}>{@emoji}</span>
      <span :if={@label != ""}>{@label}:</span>
      <span class="uppercase">{display(@value)}</span>
    </span>
    """
  end

  # ── colour mapping ───────────────────────────────────────────────────
  # Returns {tailwind_classes, dashed?}.
  # Stub fields (LON-83 spec) get dashed? = true.

  defp pill_style(:catalyst_strength, :strong), do: {"bg-success/20 text-success", false}
  defp pill_style(:catalyst_strength, :medium), do: {"bg-warning/20 text-warning", false}
  defp pill_style(:catalyst_strength, :weak), do: {"bg-error/20 text-error", false}
  defp pill_style(:catalyst_strength, :unknown), do: {"bg-base-300 opacity-60", false}

  defp pill_style(:sentiment, :positive), do: {"bg-success/20 text-success", false}
  defp pill_style(:sentiment, :neutral), do: {"bg-base-300 opacity-60", false}
  defp pill_style(:sentiment, :negative), do: {"bg-error/20 text-error", false}

  defp pill_style(:pump_fade_risk, :high), do: {"bg-error/20 text-error", false}
  defp pill_style(:pump_fade_risk, :medium), do: {"bg-warning/20 text-warning", false}
  defp pill_style(:pump_fade_risk, :low), do: {"bg-success/20 text-success", false}
  defp pill_style(:pump_fade_risk, :insufficient_data), do: {"bg-base-300 opacity-60", true}

  defp pill_style(:strategy_match, :match), do: {"bg-success/20 text-success", false}
  defp pill_style(:strategy_match, :partial), do: {"bg-warning/20 text-warning", true}
  defp pill_style(:strategy_match, :skip), do: {"bg-error/20 text-error", false}

  defp pill_style(:verdict, :trade), do: {"bg-success/20 text-success", false}
  defp pill_style(:verdict, :watch), do: {"bg-warning/20 text-warning", false}
  defp pill_style(:verdict, :skip), do: {"bg-error/20 text-error", false}

  # Catch-alls (catalyst_type, repetition) — neutral grey
  defp pill_style(_field, _value), do: {"bg-base-300", false}

  # ── tooltips for Phase 1 stubs ───────────────────────────────────────

  defp pill_tooltip(:pump_fade_risk, :insufficient_data),
    do: "Phase 1 stub — real signal lands when price-reaction history is wired."

  defp pill_tooltip(:strategy_match, :partial),
    do: "Phase 1 stub — rule-based price/float/RVOL match lands in Phase 2."

  defp pill_tooltip(_, _), do: nil

  # ── value formatting ─────────────────────────────────────────────────

  defp display(v) when is_atom(v),
    do: v |> Atom.to_string() |> String.replace("_", " ") |> String.upcase()

  defp display(v), do: v |> to_string() |> String.upcase()

  # ── news_detail ──────────────────────────────────────────────────────

  @doc """
  Five Markdown sections rendered with MDEx. Sections with empty bodies
  are omitted (the LLM may legitimately leave one blank).
  """
  attr :analysis, NewsAnalysis, required: true

  def news_detail(assigns) do
    ~H"""
    <div class="mt-3 pt-3 border-t border-base-300 space-y-3 text-sm">
      <.detail_section title="📰 Summary" body={@analysis.detail_summary} />
      <.detail_section title="✅ Positives" body={@analysis.detail_positives} />
      <.detail_section title="⚠️  Concerns" body={@analysis.detail_concerns} />
      <.detail_section title="📋 Pre-entry checklist" body={@analysis.detail_checklist} />
      <.detail_section title="🎯 Recommendation" body={@analysis.detail_recommendation} />
    </div>
    """
  end

  attr :title, :string, required: true
  attr :body, :string, default: nil

  defp detail_section(assigns) do
    ~H"""
    <section :if={@body not in [nil, ""]}>
      <h3 class="font-semibold mb-1">{@title}</h3>
      <div class="leading-relaxed [&_ul]:list-disc [&_ul]:ml-5 [&_ol]:list-decimal [&_ol]:ml-5 [&_p]:my-1
    [&_code]:bg-base-300 [&_code]:px-1 [&_code]:rounded">
        {Phoenix.HTML.raw(MDEx.to_html!(@body))}
      </div>
    </section>
    """
  end
end
