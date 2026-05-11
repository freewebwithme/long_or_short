defmodule LongOrShort.Filings.InsiderCrossReference do
  @moduledoc """
  Compute the `:insider_selling_post_filing` boolean flag that
  `LongOrShort.Tickers.get_dilution_profile/1` surfaces to news
  analysis — LON-118, Stage 9.

  ## What we're answering

  > Did an insider open-market sale of this ticker happen in the
  > window following its most recent dilution-relevant filing?

  An "active ATM + insider sells the same week" combo is a
  qualitatively stronger SHORT signal than ATM alone — the insider
  acted on the same dilution context they know. A single
  insider sale on its own is too noisy (10b5-1 plans, liquidity
  events, etc.) to act on, so this function is **only meaningful
  as a cross-reference** alongside other dilution evidence — we
  return `false` when there's no preceding dilution filing at all.

  ## What counts as a "dilution-relevant filing"

  Phase 1: every filing type **except** `:form4`. That's
  intentionally broad — false negatives (insider sale missed
  alongside real dilution) are worse for a SHORT-bias signal than
  false positives (insider sale flagged alongside a benign 8-K).
  Refining the 8-K subtype split (only `Item 3.02` / `Item 1.01`
  count as dilution) is a LON-121 calibration concern; for Phase 1
  the simple rule is enough.

  ## Window

  `:insider_post_filing_window_days` config controls the post-filing
  window. Default 30. Can be overridden per call via the
  `:window_days` opt (test-only).

  Window endpoint is also capped at the `:as_of` opt — this lets
  tests pin "today" to a specific date without faking the system
  clock. Production callers omit `:as_of` and get
  `DateTime.utc_now/0`.

  ## Performance

  Two queries — at most one Filing row (`LIMIT 1` against the
  `(ticker_id, filed_at)` index) and the InsiderTransaction read
  via `since: start_date`, `transaction_code: :open_market_sale`,
  hitting the `(ticker_id, transaction_date)` composite index.
  Typical result-set on the second query is 0–5 rows, so the
  `Enum.any?` capping against `effective_end` runs in microseconds.
  """

  require Ash.Query

  alias LongOrShort.Filings.{Filing, InsiderTransaction}

  @doc """
  Returns `true` if the ticker has an open-market insider sale
  within `:insider_post_filing_window_days` days of its most
  recent dilution-relevant filing.

  ## Opts

    * `:as_of` — `DateTime.t()` reference time. Defaults to
      `DateTime.utc_now/0`. Test-only override.
    * `:window_days` — overrides
      `:insider_post_filing_window_days` config. Test-only.
  """
  @spec insider_selling_post_dilution?(Ash.UUID.t(), keyword()) :: boolean()
  def insider_selling_post_dilution?(ticker_id, opts \\ []) do
    case latest_dilution_filing_filed_at(ticker_id) do
      nil ->
        # No dilution event to anchor against → false. "Post-dilution"
        # is meaningless without a preceding dilution filing.
        false

      filed_at ->
        as_of = Keyword.get(opts, :as_of, DateTime.utc_now())
        window_days = resolve_window_days(opts)

        start_date = DateTime.to_date(filed_at)
        window_end = DateTime.to_date(DateTime.add(filed_at, window_days * 86_400, :second))
        as_of_date = DateTime.to_date(as_of)

        effective_end =
          case Date.compare(window_end, as_of_date) do
            :gt -> as_of_date
            _ -> window_end
          end

        has_open_market_sale_between?(ticker_id, start_date, effective_end)
    end
  end

  # Most recent Filing for this ticker that is *not* a Form 4.
  # Returns `DateTime.t() | nil` (filed_at, since dilution events
  # are timed against when the disclosure landed, not the
  # underlying transaction date).
  defp latest_dilution_filing_filed_at(ticker_id) do
    Filing
    |> Ash.Query.for_read(:by_ticker, %{ticker_id: ticker_id})
    |> Ash.Query.filter(filing_type != :form4)
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> case do
      [filing] -> filing.filed_at
      [] -> nil
    end
  end

  defp has_open_market_sale_between?(ticker_id, start_date, end_date) do
    # Defensive: if window degenerates (start > end because as_of is
    # before the dilution filing), no sale is possible.
    if Date.compare(start_date, end_date) == :gt do
      false
    else
      # Use `Ash.Query.for_read` directly — `InsiderTransaction.:by_ticker`
      # exposes `:since` and `:transaction_code` as action arguments,
      # and Ash 3.x code-interface functions don't accept action
      # arguments as keyword opts (only positional, via the
      # `args:` list in the domain definition).
      InsiderTransaction
      |> Ash.Query.for_read(:by_ticker, %{
        ticker_id: ticker_id,
        since: start_date,
        transaction_code: :open_market_sale
      })
      |> Ash.read!(authorize?: false)
      |> Enum.any?(fn t -> Date.compare(t.transaction_date, end_date) != :gt end)
    end
  end

  defp resolve_window_days(opts) do
    Keyword.get(opts, :window_days) ||
      Application.get_env(:long_or_short, :insider_post_filing_window_days, 30)
  end
end
