defmodule LongOrShort.FilingsFixtures do
  @moduledoc """
  Test fixtures for the Filings domain.
  """

  alias LongOrShort.Filings

  @doc """
  Returns a map of valid attributes for ingesting a filing.
  Symbol and external_id are auto-generated to avoid collisions.
  """
  def valid_filing_attrs(overrides \\ %{}) do
    unique = System.unique_integer([:positive])

    Map.merge(
      %{
        symbol: "FIL#{unique}",
        source: :sec_edgar,
        filing_type: :_8k,
        filing_subtype: nil,
        external_id: "accession-#{unique}",
        filer_cik: "0000#{unique}",
        filed_at: DateTime.utc_now(),
        url: "https://www.sec.gov/Archives/edgar/data/#{unique}/index.htm"
      },
      overrides
    )
  end

  @doc """
  Creates a Filing via the :ingest action (which auto-creates the
  Ticker if needed). Use when the test does not care about the
  ticker resolution path.
  """
  def build_filing(overrides \\ %{}) do
    attrs = valid_filing_attrs(overrides)

    case Filings.ingest_filing(attrs, authorize?: false) do
      {:ok, filing} ->
        filing

      {:error, error} ->
        raise """
        Failed to create filing fixture.
        attrs: #{inspect(attrs)}
        error: #{inspect(error)}
        """
    end
  end

  @doc """
  Creates a Filing for an existing Ticker via the :create action
  (no ticker resolution). Useful for tests that have already set
  up a Ticker and want to attach filings to it.
  """
  def build_filing_for_ticker(ticker, overrides \\ %{}) do
    unique = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{
          source: :sec_edgar,
          filing_type: :_8k,
          filing_subtype: nil,
          external_id: "accession-#{unique}",
          filer_cik: "0000#{unique}",
          filed_at: DateTime.utc_now(),
          url: "https://www.sec.gov/Archives/edgar/data/#{unique}/index.htm",
          ticker_id: ticker.id
        },
        overrides
      )

    case Filings.create_filing(attrs, authorize?: false) do
      {:ok, filing} ->
        filing

      {:error, error} ->
        raise """
        Failed to create filing fixture for ticker.
        attrs: #{inspect(attrs)}
        error: #{inspect(error)}
        """
    end
  end

  @doc """
  Returns a map of valid attributes for creating a FilingRaw.
  Caller must supply the `:filing_id`.
  """
  def valid_filing_raw_attrs(overrides \\ %{}) do
    unique = System.unique_integer([:positive])

    Map.merge(
      %{
        raw_text: "Sample filing body #{unique}.",
        content_hash: "hash-#{unique}"
      },
      overrides
    )
  end

  @doc """
  Creates a FilingRaw row attached to the given `filing`.
  """
  def build_filing_raw(filing, overrides \\ %{}) do
    attrs =
      filing
      |> Map.fetch!(:id)
      |> then(&Map.put(valid_filing_raw_attrs(overrides), :filing_id, &1))

    case Filings.create_filing_raw(attrs, authorize?: false) do
      {:ok, raw} ->
        raw

      {:error, error} ->
        raise """
        Failed to create filing_raw fixture.
        attrs: #{inspect(attrs)}
        error: #{inspect(error)}
        """
    end
  end

  @doc """
  Returns a map of valid attributes for creating a FilingAnalysis.
  Caller must supply `:filing_id` and `:ticker_id` (or use
  `build_filing_analysis/2` which extracts them from a Filing).
  """
  def valid_filing_analysis_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        dilution_type: :atm,
        deal_size_usd: nil,
        share_count: nil,
        pricing_method: :market_minus_pct,
        pricing_discount_pct: nil,
        warrant_strike: nil,
        warrant_term_years: nil,
        atm_remaining_shares: nil,
        atm_total_authorized_shares: nil,
        shelf_total_authorized_usd: nil,
        shelf_remaining_usd: nil,
        convertible_conversion_price: nil,
        has_anti_dilution_clause: false,
        has_death_spiral_convertible: false,
        is_reverse_split_proxy: false,
        reverse_split_ratio: nil,
        summary: "ATM facility — sample fixture",
        dilution_severity: :low,
        matched_rules: [:rule_default_low],
        severity_reason: "Default low severity",
        extraction_quality: :high,
        rejected_reason: nil,
        flags: [],
        provider: "LongOrShort.AI.MockProvider",
        model: "claude-haiku-4-5-20251001",
        raw_response: %{"usage" => %{"input_tokens" => 100, "output_tokens" => 50}}
      },
      overrides
    )
  end

  @doc """
  Creates a FilingAnalysis row attached to the given `filing`.
  Pulls `:filing_id` and `:ticker_id` from the filing struct so the
  caller does not have to repeat them.
  """
  def build_filing_analysis(filing, overrides \\ %{}) do
    attrs =
      overrides
      |> valid_filing_analysis_attrs()
      |> Map.put(:filing_id, filing.id)
      |> Map.put(:ticker_id, filing.ticker_id)

    case Filings.create_filing_analysis(attrs, authorize?: false) do
      {:ok, analysis} ->
        analysis

      {:error, error} ->
        raise """
        Failed to create filing_analysis fixture.
        attrs: #{inspect(attrs)}
        error: #{inspect(error)}
        """
    end
  end

  @doc """
  Returns a map of valid attributes for creating an InsiderTransaction.
  Caller must supply `:filing_id` and `:ticker_id` (or use
  `build_insider_transaction/2` which extracts them from a Filing).
  """
  def valid_insider_transaction_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        filer_name: "Doe, John",
        filer_role: :officer,
        transaction_code: :open_market_sale,
        share_count: 10_000,
        price: Decimal.new("5.25"),
        transaction_date: ~D[2026-04-15]
      },
      overrides
    )
  end

  @doc """
  Creates an InsiderTransaction row attached to the given Form 4
  `filing`. Pulls `:filing_id` and `:ticker_id` from the filing so
  the caller does not have to repeat them.
  """
  def build_insider_transaction(filing, overrides \\ %{}) do
    attrs =
      overrides
      |> valid_insider_transaction_attrs()
      |> Map.put(:filing_id, filing.id)
      |> Map.put(:ticker_id, filing.ticker_id)

    case Filings.create_insider_transaction(attrs, authorize?: false) do
      {:ok, tx} ->
        tx

      {:error, error} ->
        raise """
        Failed to create insider_transaction fixture.
        attrs: #{inspect(attrs)}
        error: #{inspect(error)}
        """
    end
  end
end
