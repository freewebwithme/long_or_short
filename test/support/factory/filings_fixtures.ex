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
end
