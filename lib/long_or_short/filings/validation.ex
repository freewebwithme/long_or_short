defmodule LongOrShort.Filings.Validation do
  @moduledoc """
  Sanity checks for the extracted facts produced by
  `LongOrShort.Filings.Extractor` (LON-113), to be run before severity
  scoring (`LongOrShort.Filings.SeverityRules`) and persistence
  (Stage 3c, LON-115).

  Catches LLM hallucinations and data drift early — for example, a
  model misreading "12 million" as "12 billion", or extracting a
  filing whose CIK does not match the resolved ticker.

  ## Pure function

  No DB access. Caller passes the loaded `Filing` (with `filer_cik`)
  and `Ticker` (with `cik`, `last_price`, `shares_outstanding`).

  ## Failure model

  On the first violated check, returns
  `{:error, {:rejected, check_name :: atom(), context :: map()}}`.
  The `context` carries the offending values so logs and the future
  Stage 3c persistence layer can record exactly *why* the extraction
  was rejected. Callers should never silently drop — every rejection
  is visible.

  ## Nullable handling

  Every numeric extraction field is nullable (e.g. a 13-G filing has
  no `deal_size_usd`). `nil` is always considered passing — these are
  "not disclosed" signals, not extraction failures. Only present values
  go through the numeric guards.
  """

  alias LongOrShort.Filings.Filing
  alias LongOrShort.Tickers.Ticker

  @doc """
  Run all sanity checks against an extraction result.

  Returns `:ok` if every check passes, otherwise
  `{:error, {:rejected, check_name, context}}` for the first violation.
  """
  @spec validate(map(), Filing.t(), Ticker.t()) ::
          :ok | {:error, {:rejected, atom(), map()}}
  def validate(extraction, %Filing{} = filing, %Ticker{} = ticker)
      when is_map(extraction) do
    with :ok <- check_share_count_positive(extraction),
         :ok <- check_deal_size_positive(extraction),
         :ok <- check_pricing_discount_range(extraction),
         :ok <- check_warrant_strike_positive(extraction),
         :ok <- check_reverse_split_ratio_format(extraction),
         :ok <- check_share_count_bound(extraction, ticker),
         :ok <- check_implied_price_sane(extraction, ticker),
         :ok <- check_filer_cik_matches_ticker(filing, ticker) do
      :ok
    end
  end

  # ── Numeric range checks ───────────────────────────────────────

  defp check_share_count_positive(%{share_count: nil}), do: :ok
  defp check_share_count_positive(%{share_count: n}) when is_integer(n) and n > 0, do: :ok

  defp check_share_count_positive(%{share_count: n}),
    do: {:error, {:rejected, :share_count_positive, %{share_count: n}}}

  defp check_share_count_positive(_), do: :ok

  defp check_deal_size_positive(%{deal_size_usd: nil}), do: :ok
  defp check_deal_size_positive(%{deal_size_usd: n}) when is_number(n) and n > 0, do: :ok

  defp check_deal_size_positive(%{deal_size_usd: n}),
    do: {:error, {:rejected, :deal_size_positive, %{deal_size_usd: n}}}

  defp check_deal_size_positive(_), do: :ok

  defp check_pricing_discount_range(%{pricing_discount_pct: nil}), do: :ok

  defp check_pricing_discount_range(%{pricing_discount_pct: pct})
       when is_number(pct) and pct >= -50 and pct <= 50,
       do: :ok

  defp check_pricing_discount_range(%{pricing_discount_pct: pct}),
    do: {:error, {:rejected, :pricing_discount_range, %{pricing_discount_pct: pct}}}

  defp check_pricing_discount_range(_), do: :ok

  defp check_warrant_strike_positive(%{warrant_strike: nil}), do: :ok

  defp check_warrant_strike_positive(%{warrant_strike: n}) when is_number(n) and n > 0, do: :ok

  defp check_warrant_strike_positive(%{warrant_strike: n}),
    do: {:error, {:rejected, :warrant_strike_positive, %{warrant_strike: n}}}

  defp check_warrant_strike_positive(_), do: :ok

  # ── Format checks ──────────────────────────────────────────────

  defp check_reverse_split_ratio_format(%{reverse_split_ratio: nil}), do: :ok

  defp check_reverse_split_ratio_format(%{reverse_split_ratio: ratio}) when is_binary(ratio) do
    # Accept "1:10", "1-for-10", "1 for 10" (case-insensitive)
    if Regex.match?(~r/^\d+\s*(?::|-?for-?|\s+for\s+)\s*\d+$/i, ratio) do
      :ok
    else
      {:error, {:rejected, :reverse_split_ratio_format, %{reverse_split_ratio: ratio}}}
    end
  end

  defp check_reverse_split_ratio_format(_), do: :ok

  # ── Cross-checks against ticker ────────────────────────────────

  # 10× shares_outstanding upper bound — guards against the LLM reading
  # "12 million" as "12 billion" or similar magnitude errors.
  defp check_share_count_bound(%{share_count: nil}, _ticker), do: :ok

  defp check_share_count_bound(
         %{share_count: count},
         %Ticker{shares_outstanding: outstanding}
       )
       when is_integer(count) and is_integer(outstanding) and outstanding > 0 do
    max_allowed = outstanding * 10

    if count <= max_allowed do
      :ok
    else
      {:error,
       {:rejected, :share_count_bound,
        %{share_count: count, shares_outstanding: outstanding, max_allowed: max_allowed}}}
    end
  end

  # If the ticker has no shares_outstanding recorded, skip this guard
  # rather than hallucinate a violation.
  defp check_share_count_bound(_, _), do: :ok

  # When pricing_method is :fixed and both share_count and deal_size are
  # present, the implied per-share price (deal_size / share_count) should
  # be within 0.5×–2× of the ticker's last_price. Wider bands are common
  # for follow-on offerings; this catches gross magnitude errors only.
  defp check_implied_price_sane(
         %{
           pricing_method: :fixed,
           share_count: shares,
           deal_size_usd: deal
         } = extraction,
         %Ticker{last_price: last_price}
       )
       when is_integer(shares) and shares > 0 and is_number(deal) and deal > 0 and
              not is_nil(last_price) do
    last = Decimal.to_float(last_price)
    implied = deal / shares
    low = last * 0.5
    high = last * 2.0

    if implied >= low and implied <= high do
      :ok
    else
      {:error,
       {:rejected, :implied_price_sane,
        %{
          implied_price: implied,
          last_price: last,
          allowed_low: low,
          allowed_high: high,
          extraction: Map.take(extraction, [:share_count, :deal_size_usd, :pricing_method])
        }}}
    end
  end

  # If pricing isn't fixed, or last_price is missing, or required fields
  # aren't present, the implied-price check doesn't apply.
  defp check_implied_price_sane(_, _), do: :ok

  # Defense-in-depth: LON-111 feeder maps CIK → Ticker, so this should
  # never fail in practice. But if it does, we want the FilingAnalysis
  # rejected loudly rather than persisted with a wrong-ticker association.
  defp check_filer_cik_matches_ticker(%Filing{filer_cik: filer}, %Ticker{cik: ticker_cik})
       when is_binary(filer) and is_binary(ticker_cik) do
    if normalize_cik(filer) == normalize_cik(ticker_cik) do
      :ok
    else
      {:error,
       {:rejected, :filer_cik_matches_ticker,
        %{filer_cik: filer, ticker_cik: ticker_cik}}}
    end
  end

  # If either side has no CIK recorded, we can't compare — pass rather
  # than reject. Surfacing missing CIK is a Ticker data-quality concern,
  # not an extraction-validation concern.
  defp check_filer_cik_matches_ticker(_, _), do: :ok

  # CIKs are sometimes zero-padded, sometimes not. Normalize by stripping
  # leading zeros for comparison.
  defp normalize_cik(cik), do: String.trim_leading(cik, "0")
end
