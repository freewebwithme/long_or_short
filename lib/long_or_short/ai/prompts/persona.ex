defmodule LongOrShort.AI.Prompts.Persona do
  @moduledoc """
  Shared `TradingProfile` → prompt-fragment helpers used wherever an
  LLM call needs to know who's asking (LON-95 surface).

  Extracted from `LongOrShort.AI.Prompts.NewsAnalysis` once
  `LongOrShort.Research.Prompts.TickerBriefing` became the second
  consumer (LON-172). Both produce prompts that frame analysis around
  the trader's persona; consolidating these descriptors avoids the
  "persona drift" failure mode where two surfaces describe the same
  user with different words.

  ## What lives here

    * `intro/1` — short noun phrase per `trading_style` ("small-cap
      momentum day trader", "swing trader", ...) for the system prompt.
    * `render_profile_lines/1` — full bulleted user description
      (style, horizon, market cap focus, catalyst prefs, price band,
      float cap) suitable for any system-prompt persona section.
    * `render_notes/1` — optional free-form addendum block.

  Analysis-specific tone guidance (e.g. "be honest about weak
  catalysts, 5-minute scalp mindset") stays in the consuming prompt
  module — that's framing for the analysis task, not persona.
  """

  alias LongOrShort.Accounts.TradingProfile

  @doc ~S"""
  One-line noun phrase identifying the trader by style. Suitable for
  the system prompt's role declaration:
  `"You are a research analyst for a #{intro(profile.trading_style)}."`
  """
  @spec intro(atom()) :: String.t()
  def intro(:momentum_day), do: "small-cap momentum day trader"
  def intro(:large_cap_day), do: "large-cap day trader"
  def intro(:swing), do: "swing trader (multi-day to multi-week holds)"
  def intro(:position), do: "position investor (multi-week to multi-month holds)"
  def intro(:options), do: "options trader"

  @doc """
  Full bulleted profile description — style, horizon, market cap focus,
  catalyst preferences, plus optional style-specific lines (price band
  for momentum/small-cap, float cap when set).

  Accepts a `TradingProfile` struct or any map with the same keys.
  """
  @spec render_profile_lines(TradingProfile.t() | map()) :: String.t()
  def render_profile_lines(profile) do
    base_lines = [
      "  * Style: #{profile.trading_style}",
      "  * Time horizon: #{profile.time_horizon}",
      "  * Market cap focus: #{format_market_caps(profile.market_cap_focuses)}",
      "  * Catalyst preferences: #{format_catalysts(profile.catalyst_preferences)}"
    ]

    style_lines =
      [
        price_band_line(profile),
        float_line(profile)
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(base_lines ++ style_lines, "\n")
  end

  @doc """
  Optional addendum block for the `:notes` free-form field. Returns
  `""` for missing / empty notes so callers can interpolate
  unconditionally.
  """
  @spec render_notes(String.t() | nil) :: String.t()
  def render_notes(nil), do: ""
  def render_notes(""), do: ""
  def render_notes(notes), do: "\nAdditional notes:\n#{notes}\n"

  # ── Internal helpers ─────────────────────────────────────────────

  defp format_market_caps([]), do: "any"
  defp format_market_caps(focuses), do: Enum.join(focuses, ", ")

  defp format_catalysts([]), do: "any"
  defp format_catalysts(prefs), do: Enum.join(prefs, ", ")

  defp price_band_line(%{price_min: min, price_max: max})
       when not is_nil(min) and not is_nil(max),
       do: "  * Stocks priced $#{min}–$#{max}"

  defp price_band_line(_), do: nil

  defp float_line(%{float_max: max}) when not is_nil(max),
    do: "  * Float under #{format_shares(max)}"

  defp float_line(_), do: nil

  defp format_shares(n) when n >= 1_000_000_000, do: "#{div(n, 1_000_000_000)}B"
  defp format_shares(n) when n >= 1_000_000, do: "#{div(n, 1_000_000)}M"
  defp format_shares(n), do: to_string(n)
end
