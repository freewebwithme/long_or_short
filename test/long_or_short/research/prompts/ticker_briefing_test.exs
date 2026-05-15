defmodule LongOrShort.Research.Prompts.TickerBriefingTest do
  @moduledoc """
  Tests for the Pre-Trade Briefing prompt builder (LON-172, PT-1).

  Verifies:
    * messages are split into a stable `system` and a variable `user`
      block (key precondition for LON-174 PT-3 prompt caching)
    * persona content appears in `system`, ticker context in `user`
    * dilution-section copy switches by context state (full /
      :insufficient / nil)
    * recent NewsAnalysis verdicts get injected when present
  """

  use ExUnit.Case, async: true

  alias LongOrShort.Research.Prompts.TickerBriefing

  defp profile do
    %{
      trading_style: :momentum_day,
      time_horizon: :intraday,
      market_cap_focuses: [:small, :micro],
      catalyst_preferences: [:fda, :partnership],
      price_min: Decimal.new("2.0"),
      price_max: Decimal.new("10.0"),
      float_max: 50_000_000,
      notes: nil
    }
  end

  defp ticker(overrides \\ %{}) do
    Map.merge(
      %{
        symbol: "BTBD",
        company_name: "Bt Brands Inc",
        exchange: :nasdaq,
        industry: "Hotels",
        last_price: Decimal.new("4.25"),
        shares_outstanding: 6_150_000,
        float_shares: 4_000_000
      },
      overrides
    )
  end

  describe "build/3 — structure" do
    test "returns [system, user] message list" do
      [system, user] = TickerBriefing.build(ticker(), profile(), %{})

      assert system.role == "system"
      assert user.role == "user"
    end

    test "persona content lives in the system message, ticker context in user" do
      [system, user] = TickerBriefing.build(ticker(), profile(), %{})

      # Persona — system only
      assert system.content =~ "small-cap momentum day trader"
      refute user.content =~ "small-cap momentum day trader"

      # Output format spec — system only
      assert system.content =~ "TL;DR"
      assert system.content =~ "Catalyst"
      assert system.content =~ "Dilution Risk"

      # Ticker symbol + last price — user only (variable)
      assert user.content =~ "BTBD"
      assert user.content =~ "$4.25"
      refute system.content =~ "BTBD"
    end

    test "TradingProfile bullets render in system" do
      [system, _] = TickerBriefing.build(ticker(), profile(), %{})

      assert system.content =~ "Style: momentum_day"
      assert system.content =~ "Stocks priced $2.0–$10.0"
      assert system.content =~ "Float under 50M"
    end
  end

  describe "build/3 — dilution context branching" do
    test "no dilution profile → 'internal data missing' + SEC EDGAR search instruction" do
      [_, user] = TickerBriefing.build(ticker(), profile(), %{dilution_profile: nil})

      assert user.content =~ "internal data missing"
      assert user.content =~ "SEC EDGAR"
      assert user.content =~ "UNKNOWN"
    end

    test ":insufficient → fallback-to-web_search instruction" do
      [_, user] =
        TickerBriefing.build(ticker(), profile(), %{
          dilution_profile: %{data_completeness: :insufficient}
        })

      assert user.content =~ "insufficient data"
      assert user.content =~ "web_search"
      assert user.content =~ "UNKNOWN"
    end

    test "full profile → JSON inject with overall_severity" do
      profile_blob = %{
        data_completeness: :full,
        overall_severity: :high,
        active_atm: %{remaining_shares: 1_000_000},
        flags: [:death_spiral]
      }

      [_, user] =
        TickerBriefing.build(ticker(), profile(), %{dilution_profile: profile_blob})

      assert user.content =~ "Dilution context"
      # JSON inject
      assert user.content =~ ~s("data_completeness": "full")
      assert user.content =~ ~s("overall_severity": "high")
    end
  end

  describe "build/3 — recent NewsAnalysis context" do
    test "[] → section omitted entirely" do
      [_, user] =
        TickerBriefing.build(ticker(), profile(), %{recent_news_analyses: []})

      refute user.content =~ "Recent NewsAnalysis verdicts"
    end

    test "non-empty → JSON inject with verdict + headline_takeaway" do
      analyses = [
        %{
          analyzed_at: DateTime.utc_now(),
          verdict: :watch,
          catalyst_strength: :weak,
          catalyst_type: :other,
          sentiment: :neutral,
          headline_takeaway: "Thin PR catalyst"
        }
      ]

      [_, user] =
        TickerBriefing.build(ticker(), profile(), %{recent_news_analyses: analyses})

      assert user.content =~ "Recent NewsAnalysis verdicts"
      assert user.content =~ ~s("verdict": "watch")
      assert user.content =~ "Thin PR catalyst"
    end
  end

  describe "build/3 — search rules" do
    test "system message names the specific SEC filing types we care about" do
      [system, _] = TickerBriefing.build(ticker(), profile(), %{})

      assert system.content =~ "S-3"
      assert system.content =~ "424B"
      assert system.content =~ "8-K"
      assert system.content =~ "DEF 14A"
      assert system.content =~ "Form 4"
      assert system.content =~ "Maximum 5 search calls"
    end
  end
end
