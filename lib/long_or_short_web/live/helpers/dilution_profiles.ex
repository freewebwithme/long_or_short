defmodule LongOrShortWeb.Live.DilutionProfiles do
  @moduledoc """
  Shared LiveView helper for loading and refreshing per-ticker
  dilution profiles on dilution-displaying surfaces (LON-162).

  ## Pattern

  Each LiveView holds a `%{ticker_id => profile}` map on its socket
  assigns, subscribes to `Filings.Events` for `:new_filing_analysis`
  broadcasts, and refreshes the affected entry when the worker (or
  any other promoter) updates a `FilingAnalysis` row.

  Profile loading is **system-only** — `Tickers.get_dilution_profile/1`
  operates on public regulatory data with no per-user scope concern.
  This helper does not thread an `actor:` argument.

  See LON-160 Option C for the design rationale (live UI reads + the
  snapshot column deprecation that lets these helpers exist at all).

  ## Usage

      def mount(_, _, socket) do
        :ok = DilutionProfiles.subscribe()
        {:ok, assign(socket, :dilution_profiles, %{})}
      end

      # When new articles enter the view, fold their tickers into the cache:
      profiles =
        DilutionProfiles.load_for_tickers(ticker_ids)
        |> Map.merge(socket.assigns.dilution_profiles, _, fn _k, _old, new -> new end)

      def handle_info({:new_filing_analysis, fa}, socket) do
        refreshed = DilutionProfiles.refresh_one(socket.assigns.dilution_profiles, fa.ticker_id)
        {:noreply, assign(socket, :dilution_profiles, refreshed)}
        # NB: LiveViews using streams must additionally re-stream_insert
        # affected articles for the UI to actually patch. Streams are
        # freed from socket state after render, so assigns changes alone
        # don't re-render stream items.
      end
  """

  alias LongOrShort.Filings.Events
  alias LongOrShort.Tickers

  @type profile_map :: %{optional(Ash.UUID.t()) => map()}

  @doc """
  Load fresh dilution profiles for the given ticker IDs. Deduplicates
  the input list before fetching, so passing 50 articles' worth of
  ticker_ids (with many repeats) only triggers one query per unique
  ticker.

  Returns a `%{ticker_id => profile}` map.
  """
  @spec load_for_tickers([Ash.UUID.t()]) :: profile_map()
  def load_for_tickers(ticker_ids) when is_list(ticker_ids) do
    ticker_ids
    |> Enum.uniq()
    |> Map.new(fn id -> {id, Tickers.get_dilution_profile(id)} end)
  end

  @doc """
  Load a single ticker's profile directly (no surrounding map). Used by
  single-article surfaces like `AnalyzeLive` (`:show`) that don't need
  the map-keyed cache the multi-article LiveViews use.
  """
  @spec load_one(Ash.UUID.t()) :: map()
  def load_one(ticker_id), do: Tickers.get_dilution_profile(ticker_id)

  @doc """
  Subscribe to the global `"filings:analyses"` PubSub topic. The
  caller will receive `{:new_filing_analysis, %FilingAnalysis{}}` for
  every Tier 1 + Tier 2 write produced by `Filings.Analyzer` and the
  `FilingSeverityWorker` sweep (LON-136).
  """
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Events.subscribe()

  @doc """
  Re-load one ticker's profile and return the updated map. If the
  ticker isn't in the input map, returns it unchanged — the caller's
  view doesn't display that ticker right now, so there's nothing to
  refresh.
  """
  @spec refresh_one(profile_map(), Ash.UUID.t()) :: profile_map()
  def refresh_one(profile_map, ticker_id) when is_map(profile_map) do
    if Map.has_key?(profile_map, ticker_id) do
      Map.put(profile_map, ticker_id, Tickers.get_dilution_profile(ticker_id))
    else
      profile_map
    end
  end

  @doc """
  Merge profiles for any ticker IDs in `ticker_ids` that aren't already
  in `profile_map`. Existing entries are preserved (we don't re-load
  on every list mutation — `refresh_one/2` is the path for explicit
  refreshes).

  Use this after appending articles to a displayed list when you only
  want to backfill the cache for newly-seen tickers.
  """
  @spec ensure_loaded(profile_map(), [Ash.UUID.t()]) :: profile_map()
  def ensure_loaded(profile_map, ticker_ids)
      when is_map(profile_map) and is_list(ticker_ids) do
    missing =
      ticker_ids
      |> Enum.uniq()
      |> Enum.reject(&Map.has_key?(profile_map, &1))

    if missing == [] do
      profile_map
    else
      Map.merge(profile_map, load_for_tickers(missing))
    end
  end
end
