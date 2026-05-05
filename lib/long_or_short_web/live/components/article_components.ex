defmodule LongOrShortWeb.Live.Components.ArticleComponents do
  @moduledoc """
  HEEx components for rendering articles in trader-facing surfaces:
  /feed, dashboard latest-news widget, future ticker drilldown.

  The Analyze button lives here so any LiveView that hosts these cards
  can wire `handle_event("analyze", ...)` to drive the analysis flow.
  Analysis-status badges (pending / complete / failed) are intentionally
  absent during the gap between LON-80 (RepetitionAnalysis retired) and
  LON-83 (`/feed` UI rewire on top of `NewsAnalysis`); the Analyze
  button remains visible but its host LiveView shows a flash explaining
  the rebuild.
  """
  use Phoenix.Component
  use LongOrShortWeb, :verified_routes

  alias LongOrShortWeb.Format

  @doc """
  Render a single article as a card: time / ticker + live price /
  title / source / Analyze button.

  ## Attrs

  * `article` — `News.Article` with `:ticker` preloaded
  * `analysis` — reserved for the LON-83 rewire; ignored today
  * `context` — short string used to disambiguate hook ids when the
    same article renders in multiple surfaces (default `"card"`)
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

      <button
        type="button"
        phx-click="analyze"
        phx-value-id={@article.id}
        class="text-xs px-2 py-0.5 rounded bg-primary text-primary-content flex-shrink-0 hover:bg-primary-focus"
      >
        Analyze
      </button>
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
end
