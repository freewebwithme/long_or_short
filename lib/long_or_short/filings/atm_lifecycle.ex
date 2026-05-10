defmodule LongOrShort.Filings.AtmLifecycle do
  @moduledoc """
  ATM (At-the-Market offering) lifecycle resolver — LON-116, Stage 4.

  ATM is the **only** filing type that gets full lifecycle tracking in
  Phase 1 of the LON-106 epic. Reasoning (parent epic, architectural
  decision #3):

    * ATM is the most catastrophic dilution type for small-cap
      momentum trades — a quiet 6-month-old ATM with 12M shares
      remaining will eat any catalyst the moment it ignites.
    * Window-based aggregation alone would miss exactly that
      scenario: an ATM registered 200 days ago that is still
      actively bleeding shares today drops out of a 180-day window.
    * The ATM chain is well-defined enough to walk
      deterministically: an S-3 registration with an ATM provision,
      then 424B5 prospectus supplements reporting incremental
      shares sold.

  Other filing types (S-3 shelf, warrants, convertibles) get
  window-only treatment — `Tickers.DilutionProfile`'s responsibility.

  ## Algorithm

      1. Load every `FilingAnalysis` for the ticker with
         `dilution_type == :atm`, eager-loading the `:filing`
         relationship for `filing_type` / `filed_at`.
      2. Find the **most recent registration**: filing whose
         `filing_type in [:s3, :s3a]` and whose
         `atm_total_authorized_shares` is populated.
      3. Among 424B5 supplements filed *after* the registration,
         sum `:share_count` → `used_to_date`.
      4. `remaining_shares = atm_total_authorized_shares - used_to_date`.

  Returns `nil` when:

    * No `dilution_type == :atm` rows exist for the ticker.
    * 424B5 supplements exist but no parent S-3 registration was
      found — logged as an **orphan** at `:warning`. The caller's
      `DilutionProfile` surfaces this via
      `data_completeness: :partial` rather than crashing.
    * `remaining_shares <= 0` — facility exhausted.
    * Last 424B5 is older than `@dormancy_cutoff_days` — treated as
      dormant. Dormant ATMs are not yet exhausted on paper, but
      companies rarely resume a stale ATM without filing fresh
      paperwork, so they are not active dilution overhang.

  ## Phase 1 simplifications (intentional)

    * **No explicit withdrawal detection.** A withdrawal would
      arrive as a specific 8-K filing subtype which Phase 1 does
      not parse. Dormancy (`@dormancy_cutoff_days`) covers the
      typical case where a withdrawn ATM simply stops generating
      424B5s.
    * **No Item 1.01 activation tracking.** The S-3 registration
      already carries `atm_total_authorized_shares`, which is all
      `remaining_shares` needs.
    * **`:atm_remaining_shares` LLM extraction is not used.** The
      ticket spec is deterministic — `total - used`. If the
      LLM-extracted remaining-shares field stabilizes enough to
      cross-check, that becomes a calibration ticket under LON-121.

  ## Testability

  `resolve/2` accepts `as_of:` so tests can pin the dormancy
  boundary deterministically without freezing `DateTime.utc_now/0`.
  Production callers omit it and get current UTC.
  """

  require Ash.Query
  require Logger

  alias LongOrShort.Filings.FilingAnalysis

  # 6 months. An ATM with no 424B5 supplements in this window is
  # treated as dormant — see the moduledoc on why Phase 1 prefers
  # dormancy over explicit withdrawal detection.
  @dormancy_cutoff_days 180

  @type result :: %{
          remaining_shares: integer(),
          pricing_method: atom(),
          pricing_discount_pct: Decimal.t() | nil,
          registered_at: DateTime.t(),
          used_to_date: integer(),
          last_424b_filed_at: DateTime.t() | nil,
          source_filing_ids: [String.t()]
        }

  @doc """
  Resolve the currently-active ATM facility for `ticker_id`, or `nil`.

  See moduledoc for the full algorithm and return semantics.

  Options:

    * `:as_of` — `DateTime.t()`; reference time for the dormancy
      cutoff. Defaults to `DateTime.utc_now/0`. Test-only override.
  """
  @spec resolve(Ash.UUID.t(), keyword()) :: result() | nil
  def resolve(ticker_id, opts \\ []) do
    as_of = Keyword.get(opts, :as_of, DateTime.utc_now())

    case load_atm_analyses(ticker_id) do
      [] ->
        nil

      analyses ->
        case find_registration(analyses) do
          nil ->
            maybe_log_orphan(ticker_id, analyses)
            nil

          registration ->
            build_result(registration, analyses, as_of)
        end
    end
  end

  defp load_atm_analyses(ticker_id) do
    FilingAnalysis
    |> Ash.Query.for_read(:by_ticker, %{ticker_id: ticker_id})
    |> Ash.Query.filter(dilution_type == :atm)
    |> Ash.Query.load(:filing)
    |> Ash.read!(authorize?: false)
  end

  defp find_registration(analyses) do
    analyses
    |> Enum.filter(fn a ->
      a.filing.filing_type in [:s3, :s3a] and not is_nil(a.atm_total_authorized_shares)
    end)
    |> Enum.max_by(&DateTime.to_unix(&1.filing.filed_at, :microsecond), fn -> nil end)
  end

  defp maybe_log_orphan(ticker_id, analyses) do
    if Enum.any?(analyses, fn a -> a.filing.filing_type == :_424b5 end) do
      Logger.warning(
        "[AtmLifecycle] orphan 424B5 for ticker_id=#{inspect(ticker_id)} — no parent S-3 registration found, skipping ATM profile"
      )
    end
  end

  defp build_result(registration, analyses, as_of) do
    usage =
      analyses
      |> Enum.filter(fn a ->
        a.filing.filing_type == :_424b5 and
          DateTime.compare(a.filing.filed_at, registration.filing.filed_at) == :gt and
          is_integer(a.share_count)
      end)

    used_to_date = usage |> Enum.map(& &1.share_count) |> Enum.sum()
    remaining = registration.atm_total_authorized_shares - used_to_date
    last_424b_filed_at = last_filed_at(usage)

    cond do
      remaining <= 0 ->
        nil

      dormant?(last_424b_filed_at, as_of) ->
        nil

      true ->
        %{
          remaining_shares: remaining,
          pricing_method: registration.pricing_method,
          pricing_discount_pct: registration.pricing_discount_pct,
          registered_at: registration.filing.filed_at,
          used_to_date: used_to_date,
          last_424b_filed_at: last_424b_filed_at,
          source_filing_ids: [registration.filing_id | Enum.map(usage, & &1.filing_id)]
        }
    end
  end

  defp last_filed_at([]), do: nil
  defp last_filed_at(usage), do: usage |> Enum.map(& &1.filing.filed_at) |> Enum.max(DateTime)

  defp dormant?(nil, _as_of), do: false

  defp dormant?(last_424b_filed_at, as_of) do
    cutoff = DateTime.add(as_of, -@dormancy_cutoff_days * 86_400, :second)
    DateTime.compare(last_424b_filed_at, cutoff) == :lt
  end
end
