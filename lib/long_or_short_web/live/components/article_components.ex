defmodule LongOrShortWeb.Live.Components.ArticleComponents do
  @moduledoc """
  HEEx components for rendering articles in trader-facing surfaces:
  /feed, dashboard latest-news widget, future ticker drilldown.

  The Analyze button + analysis-status badges live here so any
  LiveView that hosts these cards can wire `handle_event("analyze",
  ...)` and the `:repetition_analysis_*` handle_info clauses to get
  the same behaviour as `/feed`.
  """
  use Phoenix.Component
  use LongOrShortWeb, :verified_routes

  alias LongOrShortWeb.Format

  @doc """
  Render a single article as a card: time / ticker + live price /
  title / source / analyze button or status badge.

  ## Attrs

  * `article` — `News.Article` with `:ticker` preloaded
  * `analysis` — latest `RepetitionAnalysis` for the article, or nil
  """
  attr :article, :map, required: true
  attr :analysis, :any, default: nil
  attr :context, :string, default: "card"

  def article_card(assigns) do
    ~H"""
    <div class="border border-base-300 rounded p-3 bg-base-200 shadow-sm flex gap-3 items-start">
      <div class="text-xs opacity-60 w-20 flex-shrink-0">
        <time datetime={DateTime.to_iso8601(@article.published_at)}>
          {Format.relative_time(@article.published_at)}
        </time>
      </div>

      <div class="w-20 flex-shrink-0">
        <div class="font-bold">{@article.ticker.symbol}</div>
        <.price_label
          id={"price-#{@context}-#{@article.id}"}
          symbol={@article.ticker.symbol}
          initial_price={@article.ticker.last_price}
          class="text-xs opacity-60"
        />
      </div>

      <div class="flex-grow">{@article.title}</div>

      <div class="text-xs px-2 py-0.5 rounded bg-base-300 flex-shrink-0">
        {@article.source}
      </div>

      <.analysis_cell analysis={@analysis} article_id={@article.id} />
    </div>
    """
  end

  # ── Price label (reusable, hook anchored here) ──

  attr :id, :string, required: true
  attr :symbol, :string, required: true
  attr :initial_price, :any, default: nil
  attr :class, :string, default: ""

  def price_label(assigns) do
    ~H"""
    <span
      id={@id}
      phx-hook=".PriceLabel"
      data-symbol={@symbol}
      data-initial-price={Format.price(@initial_price)}
      class={@class}
    >
    </span>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".PriceLabel">
      export default {
        mounted() {
          this.symbol = this.el.dataset.symbol
          const initial = this.el.dataset.initialPrice
          if (initial && initial !== "") {
            this.el.textContent = `$${initial}`
          }
          this.handler = (e) => {
            if (e.detail.symbol === this.symbol) {
              this.el.textContent = `$${e.detail.price}`
            }
          }
          window.addEventListener("phx:price_tick", this.handler)
        },
        destroyed() {
          window.removeEventListener("phx:price_tick", this.handler)
        }
      }
    </script>
    """
  end

  attr :analysis, :any, required: true
  attr :article_id, :string, required: true

  def analysis_cell(%{analysis: nil} = assigns) do
    ~H"""
    <button
      type="button"
      phx-click="analyze"
      phx-value-id={@article_id}
      class="text-xs px-2 py-0.5 rounded bg-primary text-primary-content flex-shrink-0 hover:bg-primary-focus"
    >
      Analyze
    </button>
    """
  end

  def analysis_cell(%{analysis: %{status: :pending}} = assigns) do
    ~H"""
    <div class="text-xs italic opacity-60 flex-shrink-0">analyzing…</div>
    """
  end

  def analysis_cell(%{analysis: %{status: :complete} = a} = assigns) do
    assigns = assign(assigns, :a, a)

    ~H"""
    <div class="flex gap-1 items-center text-xs flex-shrink-0">
      <span
        class={"w-2 h-2 rounded-full #{fatigue_color(@a.fatigue_level)}"}
        title={"fatigue: #{@a.fatigue_level}"}
      />
      <span :if={@a.is_repetition} class="opacity-80">🔁 {@a.repetition_count}×</span>
      <span :if={@a.theme} class="px-1.5 py-0.5 rounded bg-base-300 opacity-80 max-w-[10rem] truncate">
        {@a.theme}
      </span>
    </div>
    """
  end

  def analysis_cell(%{analysis: %{status: :failed} = a} = assigns) do
    assigns = assign(assigns, :a, a)

    ~H"""
    <div class="text-xs flex-shrink-0" title={@a.error_message || "analysis failed"}>
      <span class="text-error">⚠</span>
    </div>
    """
  end

  defp fatigue_color(:low), do: "bg-success"
  defp fatigue_color(:medium), do: "bg-warning"
  defp fatigue_color(:high), do: "bg-error"
  defp fatigue_color(_), do: "bg-base-300"
end
