defmodule LongOrShort.Research do
  @moduledoc """
  Research domain — AI-driven on-demand investigations into a specific
  ticker at a specific lifecycle moment (LON-171 epic).

  Distinct from `LongOrShort.Analysis`, which holds **passive** AI
  outputs (article verdicts, scheduled market briefs). Research is
  **actively triggered** — a trader asks "what should I know about
  TICKER right now?" — and the system runs the LLM with `web_search`
  to produce a structured briefing.

  Ships:

    * `TickerBriefing` (LON-172) — Pre-Trade Briefing: per-ticker
      research card produced before entry. Personalized to the
      requesting trader's profile.

  Future resources (e.g. `TradeReview` for Post-Trade reflection)
  land here alongside.

  ## Lifecycle moment vs. analysis surface

  Three trading lifecycle moments now each have an AI surface:

    * **Morning** — `Analysis.MorningBriefDigest` (shared, cron, market commentary)
    * **Pre-Trade** — `Research.TickerBriefing` (personal, on-demand, ticker-specific)
    * **Post-Trade** — `Research.TradeReview` (planned, on-demand, after exit)
  """

  use Ash.Domain, otp_app: :long_or_short

  resources do
    resource LongOrShort.Research.TickerBriefing do
      define :create_ticker_briefing, action: :create
      define :upsert_ticker_briefing, action: :upsert

      # Primary-key lookup — used by LiveView callbacks that receive
      # a briefing_id via PubSub and need to load the full row.
      define :get_ticker_briefing,
        action: :read,
        get_by: [:id]

      # Page-load path: caller asks "is there a fresh briefing for
      # (ticker, user)?". `get?: true` + not_found_error?: false so
      # the cache-miss branch in the Generator gets a plain nil
      # instead of an exception.
      define :get_latest_briefing_for,
        action: :get_latest_for,
        args: [:symbol, :user_id],
        get?: true,
        not_found_error?: false

      define :list_recent_briefings_by_user,
        action: :by_user,
        args: [:user_id]

      define :destroy_ticker_briefing, action: :destroy
    end
  end
end
