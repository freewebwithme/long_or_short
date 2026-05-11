defmodule LongOrShortWeb.Live.Components.ArticleComponents do
  @moduledoc """
  HEEx components for rendering articles in trader-facing surfaces:
  /feed, dashboard latest-news widget, future ticker drilldown.

  `article_card` is state-aware:

    * No analysis, not analyzing → Analyze button visible
    * `:analyzing?` true → spinner badge + skeleton bar, button hidden
    * `:analysis` present → `news_card` + (if `:expanded?`) `news_detail`,
      header Analyze button hidden

  Host LiveViews wire `handle_event("analyze", _, _)`,
  `handle_event("toggle_detail", _, _)`, and
  `handle_info({:news_analysis_ready, _}, _)` to drive the flow.
  """
  use Phoenix.Component
  use LongOrShortWeb, :verified_routes

  alias LongOrShortWeb.Format
  alias LongOrShortWeb.Live.Components.NewsComponents

  @doc """
  Render a single article as a card.

  ## Attrs
    * `:article` — `News.Article` with `:ticker` preloaded
    * `:analysis` — `%NewsAnalysis{} | nil`. Caller is responsible for
      pulling `article.news_analysis` (or whatever source) and passing
      a struct or nil — no Ash `NotLoaded` should reach here.
    * `:analyzing?` — true while the analyzer is running for this article
    * `:analyze_disabled?` — true when the user has no `TradingProfile`
      yet. Renders the Analyze button as a muted link to `/profile` with
      a tooltip explaining why; the analyzer is never invoked profile-
      less so the LLM call isn't wasted on a generic persona (LON-102).
    * `:expanded?` — whether the Detail view is open
    * `:context` — short string for hook id disambiguation (default `"card"`)
  """
  attr :article, :map, required: true
  attr :analysis, :any, default: nil
  attr :analyzing?, :boolean, default: false
  attr :analyze_disabled?, :boolean, default: false
  attr :expanded?, :boolean, default: false
  attr :context, :string, default: "card"

  def article_card(assigns) do
    ~H"""
    <div class="border border-base-300 rounded p-3 bg-base-200 shadow-sm">
      <div class="flex gap-3 items-start">
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

        <.analyze_status
          analyzing?={@analyzing?}
          has_analysis?={not is_nil(@analysis)}
          disabled?={@analyze_disabled?}
          article_id={@article.id}
        />
      </div>

      <div :if={@analyzing?} class="mt-3 pt-3 border-t border-base-300">
        <div class="h-4 bg-base-300 rounded animate-pulse w-3/4"></div>
      </div>

      <NewsComponents.news_card
        :if={@analysis && not @analyzing?}
        analysis={@analysis}
        expanded?={@expanded?}
      />

      <NewsComponents.news_detail
        :if={@analysis && @expanded?}
        analysis={@analysis}
      />

      <div :if={@article.url} class="mt-2 flex justify-end">
        <a
          href={@article.url}
          target="_blank"
          rel="noopener noreferrer"
          onclick="return confirm('외부 링크로 이동합니다. 계속하시겠습니까?')"
          class="text-xs opacity-60 hover:opacity-100 inline-flex items-center gap-1"
        >
          Detail <span aria-hidden="true">↗</span>
        </a>
      </div>
    </div>
    """
  end

  # ── analyze_status: the slot in the card header that switches based on state ──

  attr :analyzing?, :boolean, required: true
  attr :has_analysis?, :boolean, required: true
  attr :disabled?, :boolean, required: true
  attr :article_id, :string, required: true

  defp analyze_status(assigns) do
    ~H"""
    <span
      :if={@analyzing?}
      class="text-xs px-2 py-0.5 rounded bg-base-300 flex-shrink-0 inline-flex items-center gap-1
    opacity-60"
    >
      <span class="loading loading-spinner loading-xs"></span> Analyzing…
    </span>

    <span
      :if={not @analyzing? and not @has_analysis? and @disabled?}
      class="tooltip tooltip-left"
      data-tip="Set up your trader profile to enable AI analysis."
    >
      <.link
        navigate={~p"/profile"}
        class="text-xs px-2 py-0.5 rounded bg-base-300 text-base-content opacity-60 flex-shrink-0
      hover:opacity-100"
      >
        Analyze
      </.link>
    </span>

    <button
      :if={not @analyzing? and not @has_analysis? and not @disabled?}
      type="button"
      phx-click="analyze"
      phx-value-id={@article_id}
      class="text-xs px-2 py-0.5 rounded bg-primary text-primary-content flex-shrink-0
    hover:bg-primary-focus"
    >
      Analyze
    </button>
    """
  end

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
