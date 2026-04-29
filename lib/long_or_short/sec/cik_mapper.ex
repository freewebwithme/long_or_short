defmodule LongOrShort.Sec.CikMapper do
  @moduledoc """
  Downloads SEC's official CIK ↔ ticker mapping and upserts it into
  the tickers table.

  Source: https://www.sec.gov/files/company_tickers.json

  Run once at application startup. Each entry becomes (or updates) a
  Ticker row with `:cik` and `:company_name` populated.
  """

  require Logger

  alias LongOrShort.Tickers

  @url "https://www.sec.gov/files/company_tickers.json"

  @doc """
  Fetches the SEC mapping and upserts every entry into the tickers table.

  Returns `:ok` on success or `{:error, reason}` on fetch failure.
  """
  def sync do
    user_agent = Application.fetch_env!(:long_or_short, :sec_user_agent)

    Logger.info("CikMapper: starting sync")

    case Req.get(@url, headers: [{"user-agent", user_agent}]) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {ok_count, skipped_count, error_count} = upsert_all(body)

        Logger.info(
          "CikMapper: sync complete — " <>
            "#{ok_count} upserted, #{skipped_count} skipped (duplicate CIK), #{error_count} failed"
        )

        :ok

      {:ok, %{status: status}} ->
        Logger.error("CikMapper: SEC returned HTTP #{status}")
        {:error, {:http_status, status}}

      {:error, reason} ->
        Logger.error("CikMapper: fetch failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp upsert_all(body) do
    body
    |> Map.values()
    |> Enum.reduce({0, 0, 0}, fn entry, {ok, skipped, err} ->
      case upsert_one(entry) do
        {:ok, :skipped_duplicate_cik} ->
          {ok, skipped + 1, err}

        {:ok, _} ->
          {ok + 1, skipped, err}

        {:error, reason} ->
          if err < 5 do
            # First 5 errors only - don't flood logs
            Logger.warning("CikMapper: upsert failed for #{inspect(entry)}: #{inspect(reason)}")
          end

          {ok, skipped, err + 1}
      end
    end)
  end

  defp upsert_one(%{"cik_str" => cik, "ticker" => ticker, "title" => title}) do
    cik_padded = cik |> to_string() |> String.pad_leading(10, "0")

    result =
      Tickers.upsert_ticker_by_symbol(
        %{
          symbol: String.upcase(ticker),
          cik: cik_padded,
          company_name: title
        },
        authorize?: false
      )

    case result do
      {:ok, _} = ok ->
        ok

      {:error, %Ash.Error.Invalid{errors: errors}} = err ->
        if Enum.any?(errors, &cik_already_taken?/1) do
          # Same CIK already mapped to another ticker (e.g. preferred share,
          # ADR variant). Skip silently — we keep the first-seen mapping.
          {:ok, :skipped_duplicate_cik}
        else
          err
        end

      other ->
        other
    end
  end

  defp cik_already_taken?(%Ash.Error.Changes.InvalidAttribute{
         field: :cik,
         private_vars: private_vars
       }) do
    Keyword.get(private_vars, :constraint) == "tickers_unique_cik_index"
  end

  defp cik_already_taken?(_), do: false
end
