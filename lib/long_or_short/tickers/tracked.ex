defmodule LongOrShort.Tickers.Tracked do
  @moduledoc """
  The ingestion universe — the set of ticker symbols the system polls
  for news and profile data.

  This is NOT the trader's personal watchlist. It is a static list
  bounded by Finnhub's free-tier rate limit (60 calls/min), maintained
  in `priv/tracked_tickers.txt`. Editing the file and restarting the
  consuming GenServer is enough to pick up changes — no recompile needed.

  The per-user dynamic watchlist (LON-90 / LON-92) is a separate
  DB-backed resource. Dashboard widgets and the AI analysis trigger will
  read from that resource instead of this module once LON-90 ships.

  ## Test override

  Set `:tracked_tickers_override` in the application env to bypass the
  file:

      Application.put_env(:long_or_short, :tracked_tickers_override,
        ~w(AAPL TSLA))

  """
  @spec symbols() :: [String.t()]
  def symbols do
    case Application.get_env(:long_or_short, :tracked_tickers_override) do
      list when is_list(list) -> normalize(list)
      _ -> read_and_parse()
    end
  end

  # Public for testing — pure parser, no I/O.
  @doc false
  def parse(body) when is_binary(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> normalize()
  end

  defp normalize(list), do: list |> Enum.map(&String.upcase/1) |> Enum.uniq()

  defp read_and_parse do
    case File.read(path()) do
      {:ok, body} -> parse(body)
      {:error, _} -> []
    end
  end

  defp path do
    Application.app_dir(:long_or_short, "priv/tracked_tickers.txt")
  end
end
