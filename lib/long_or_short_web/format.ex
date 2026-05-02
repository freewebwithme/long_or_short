defmodule LongOrShortWeb.Format do
  @moduledoc """
  Display formatters for trader-facing values.

  Called from LiveViews and templates to render Decimals,
  percentages, and timestamps in the conventions used across
  the app. Pure functions — no side effects, no socket access.
  """

  @doc """
  Format a price as a 2-decimal-rounded string. Nil and
  non-Decimal values render as an empty string so callers can
  drop the result directly into HEEx without nil-guards.

      iex> price(Decimal.new("215.42"))
      "215.42"
      iex> price(Decimal.new("100"))
      "100.00"
      iex> price(nil)
      ""
  """
  @spec price(any()) :: String.t()
  def price(%Decimal{} = d), do: d |> Decimal.round(2) |> Decimal.to_string()
  def price(_), do: ""

  @doc """
  Render a DateTime as a short relative-time label suitable for
  feed cards: "just now", "5m ago", "3h ago", "2d ago".
  """
  @spec relative_time(DateTime.t()) :: String.t()
  def relative_time(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86_400)}d ago"
    end
  end

  @doc """
  Format a large share/volume count compactly.

      iex> shares(16_350_000_000)
      "16.35B"
      iex> shares(50_000_000)
      "50.00M"
      iex> shares(nil)
      "—"
  """
  @spec shares(any()) :: String.t()
  def shares(n) when is_integer(n) and n >= 1_000_000_000,
    do: :erlang.float_to_binary(n / 1_000_000_000, decimals: 2) <> "B"

  def shares(n) when is_integer(n) and n >= 1_000_000,
    do: :erlang.float_to_binary(n / 1_000_000, decimals: 2) <> "M"

  def shares(n) when is_integer(n) and n >= 0,
    do: Integer.to_string(n)

  def shares(_), do: "—"

  @doc """
  Formats a percent change Decimal with sign-less 2-decimal precision.

  iex> pct(Decimal.new("0.84"))
  "0.84%"

  iex> pct(Decimal.new("-1.234"))
  "-1.23%"

  iex> pct(nil)
  "—"
  """
  @spec pct(Decimal.t() | nil) :: String.t()
  def pct(nil), do: "—"

  def pct(%Decimal{} = d) do
    d |> Decimal.round(2) |> Decimal.to_string() |> then(&"#{&1}%")
  end
end
