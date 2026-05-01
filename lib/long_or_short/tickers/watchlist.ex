defmodule LongOrShort.Tickers.Watchlist do
  @moduledoc """
  Single source of truth for "which symbols is the system tracking".

  Backed by `priv/watchlist.txt` — one symbol per line, `#`-prefixed
  lines are comments, blank lines ignored. Read fresh on every call,
  so editing the file plus restarting the consuming GenServer is
  enough to pick up changes (no recompile).

  ## Test override

  Set `:watchlist_override` in the application env to bypass the file:

      Application.put_env(:long_or_short, :watchlist_override,
        ~w(AAPL TSLA))

  ## LON-36 path forward

  When the DB-backed per-user watchlist ships, this module's
  `symbols/0` body switches to a DB query. Callers
  (`News.Sources.Finnhub`, `Tickers.Workers.FinnhubProfileSync`,
  the LON-60 price stream) stay untouched.
  """
  @spec symbols() :: [String.t()]
  def symbols do
    case Application.get_env(:long_or_short, :watchlist_override) do
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
    Application.app_dir(:long_or_short, "priv/watchlist.txt")
  end
end
