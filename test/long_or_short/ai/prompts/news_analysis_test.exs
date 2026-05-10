defmodule LongOrShort.AI.Prompts.NewsAnalysisTest do
  use ExUnit.Case, async: true

  doctest LongOrShort.AI.Prompts.NewsAnalysis

  alias LongOrShort.AI.Prompts.NewsAnalysis

  defp article(overrides \\ %{}) do
    Map.merge(
      %{
        title: "BTBD partners with Aero Velocity",
        summary: "Bit Digital announces a new aerospace partnership.",
        source: :finnhub,
        published_at: ~U[2026-04-20 12:00:00Z],
        ticker: %{symbol: "BTBD"}
      },
      overrides
    )
  end

  defp past(i, overrides \\ %{}) do
    Map.merge(
      %{
        title: "BTBD past announcement #{i}",
        published_at: DateTime.add(~U[2026-04-15 12:00:00Z], -i, :day)
      },
      overrides
    )
  end

  # Default = momentum_day persona, matches the seed values. Overrides
  # let individual tests vary trading_style or specific fields.
  defp profile(overrides \\ %{}) do
    Map.merge(
      %{
        trading_style: :momentum_day,
        time_horizon: :intraday,
        market_cap_focuses: [:micro, :small],
        catalyst_preferences: [:partnership, :fda, :ma, :contract_win],
        notes: nil,
        price_min: Decimal.new("2.0"),
        price_max: Decimal.new("10.0"),
        float_max: 50_000_000
      },
      overrides
    )
  end

  # Default dilution profile for tests that don't care about dilution
  # context — `:insufficient` so the prompt renders the "no data"
  # branch with the smallest footprint. Dilution-specific tests below
  # call `NewsAnalysis.build/4` directly with an explicit profile.
  defp dilution_profile(overrides \\ %{}) do
    Map.merge(
      %{
        ticker_id: "test-ticker-id",
        overall_severity: :none,
        overall_severity_reason: nil,
        active_atm: nil,
        pending_s1: nil,
        warrant_overhang: nil,
        recent_reverse_split: nil,
        insider_selling_post_filing: false,
        flags: [],
        last_filing_at: nil,
        data_completeness: :insufficient
      },
      overrides
    )
  end

  # Test-local wrapper around `NewsAnalysis.build/4` that defaults
  # the dilution profile. Keeps existing call sites unchanged while
  # the source moved to 4-arity (LON-117).
  defp build(article, past_articles, profile) do
    LongOrShort.AI.Prompts.NewsAnalysis.build(
      article,
      past_articles,
      profile,
      dilution_profile()
    )
  end

  describe "build/4 — message envelope" do
    test "returns [system, user]" do
      assert [%{role: "system", content: sys}, %{role: "user", content: usr}] =
               build(article(), [], profile())

      assert is_binary(sys)
      assert is_binary(usr)
    end

    test "system prompt instructs the tool path" do
      [%{content: sys}, _] = build(article(), [], profile())

      assert sys =~ "trader's analyst"
      assert sys =~ "record_news_analysis"
      assert sys =~ "respond in plain text"
    end
  end

  describe "build/4 — user message rendering" do
    test "includes ticker, title, summary, source" do
      [_, %{content: content}] =
        build(
          article(%{
            title: "TSLA delivers record",
            summary: "Tesla beats expectations.",
            source: :benzinga,
            ticker: %{symbol: "TSLA"}
          }),
          [],
          profile()
        )

      assert content =~ "TSLA"
      assert content =~ "TSLA delivers record"
      assert content =~ "Tesla beats expectations."
      assert content =~ "benzinga"
    end

    test "renders (no summary) when summary is nil" do
      [_, %{content: content}] =
        build(article(%{summary: nil}), [], profile())

      assert content =~ "(no summary)"
    end

    test "renders (no summary) when summary is empty string" do
      [_, %{content: content}] =
        build(article(%{summary: ""}), [], profile())

      assert content =~ "(no summary)"
    end
  end

  describe "build/4 — past articles rendering" do
    test "shows placeholder when past_articles is empty" do
      [_, %{content: content}] = build(article(), [], profile())
      assert content =~ "(no past articles in window)"
    end

    test "renders a single past article" do
      one = past(1, %{title: "Earlier news"})
      [_, %{content: content}] = build(article(), [one], profile())

      assert content =~ "Earlier news"
      refute content =~ "(no past articles"
    end

    test "renders multiple past articles in given order" do
      pasts = Enum.map(1..3, &past/1)
      [_, %{content: content}] = build(article(), pasts, profile())

      for a <- pasts do
        assert content =~ a.title
      end
    end
  end

  describe "build/4 — profile rendering (momentum_day default)" do
    test "renders persona intro for trading_style" do
      [%{content: sys}, _] = build(article(), [], profile())
      assert sys =~ "small-cap momentum day trader"
    end

    test "renders structured profile lines (style, horizon, market caps, catalysts)" do
      [%{content: sys}, _] = build(article(), [], profile())

      assert sys =~ "Style: momentum_day"
      assert sys =~ "Time horizon: intraday"
      assert sys =~ "Market cap focus: micro, small"
      assert sys =~ "partnership, fda, ma, contract_win"
    end

    test "renders price band when both min and max are set" do
      [%{content: sys}, _] = build(article(), [], profile())
      assert sys =~ "$2"
      assert sys =~ "$10"
    end

    test "renders float ceiling formatted in M units" do
      [%{content: sys}, _] = build(article(), [], profile())
      assert sys =~ "Float under 50M"
    end

    test "formats large floats in B units" do
      [%{content: sys}, _] =
        build(article(), [], profile(%{float_max: 2_500_000_000}))

      assert sys =~ "Float under 2B"
    end
  end

  describe "build/4 — nullable style fields" do
    test "omits price band line when min is nil" do
      [%{content: sys}, _] =
        build(article(), [], profile(%{price_min: nil}))

      refute sys =~ "Stocks priced"
    end

    test "omits price band line when max is nil" do
      [%{content: sys}, _] =
        build(article(), [], profile(%{price_max: nil}))

      refute sys =~ "Stocks priced"
    end

    test "omits float line when float_max is nil" do
      [%{content: sys}, _] =
        build(article(), [], profile(%{float_max: nil}))

      refute sys =~ "Float under"
    end

    test "renders 'any' for empty market_cap_focuses" do
      [%{content: sys}, _] =
        build(article(), [], profile(%{market_cap_focuses: []}))

      assert sys =~ "Market cap focus: any"
    end

    test "renders 'any' for empty catalyst_preferences" do
      [%{content: sys}, _] =
        build(article(), [], profile(%{catalyst_preferences: []}))

      assert sys =~ "Catalyst preferences: any"
    end
  end

  describe "build/4 — notes" do
    test "omits 'Additional notes:' block when notes is nil" do
      [%{content: sys}, _] =
        build(article(), [], profile(%{notes: nil}))

      refute sys =~ "Additional notes:"
    end

    test "omits 'Additional notes:' block when notes is empty string" do
      [%{content: sys}, _] =
        build(article(), [], profile(%{notes: ""}))

      refute sys =~ "Additional notes:"
    end

    test "renders notes when present" do
      [%{content: sys}, _] =
        build(article(), [], profile(%{notes: "Avoid Friday afternoon trades."}))

      assert sys =~ "Additional notes:"
      assert sys =~ "Avoid Friday afternoon trades."
    end
  end

  describe "build/4 — style-variation (momentum vs swing)" do
    test "momentum_day persona uses scalp framing" do
      [%{content: sys}, _] =
        build(article(), [], profile(%{trading_style: :momentum_day}))

      assert sys =~ "small-cap momentum day trader"
      assert sys =~ "5-minute scalp"
      assert sys =~ "fade risk"
    end

    test "swing persona uses multi-day continuation framing" do
      [%{content: sys}, _] =
        build(article(), [], profile(%{trading_style: :swing}))

      assert sys =~ "swing trader"
      assert sys =~ "multi-day continuation"
      refute sys =~ "5-minute scalp"
    end

    test "large_cap_day persona references typical reaction range" do
      [%{content: sys}, _] =
        build(article(), [], profile(%{trading_style: :large_cap_day}))

      assert sys =~ "large-cap day trader"
      assert sys =~ "typical reaction range"
      refute sys =~ "5-minute scalp"
    end

    test "position persona uses thesis framing" do
      [%{content: sys}, _] =
        build(article(), [], profile(%{trading_style: :position}))

      assert sys =~ "position investor"
      assert sys =~ "long-term thesis"
      refute sys =~ "5-minute scalp"
    end

    test "options persona references implied volatility" do
      [%{content: sys}, _] =
        build(article(), [], profile(%{trading_style: :options}))

      assert sys =~ "options trader"
      assert sys =~ "implied volatility"
      refute sys =~ "5-minute scalp"
    end
  end

  describe "build/4 — guideline content" do
    test "instructs the model to call the tool, not respond in text" do
      [_, %{content: content}] = build(article(), [], profile())

      assert content =~ "record_news_analysis"
      assert content =~ "Do not respond in plain text"
    end

    test "explains repetition counting convention" do
      [_, %{content: content}] = build(article(), [], profile())

      assert content =~ "Count the new article in repetition_count"
      assert content =~ "First occurrence = 1"
    end

    test "stays under sane token budget (~5k chars) with 5 past articles" do
      pasts = Enum.map(1..5, &past/1)

      [%{content: sys}, %{content: usr}] =
        build(article(), pasts, profile())

      total = byte_size(sys) + byte_size(usr)

      # Bumped from 4k to 5k in LON-117 — system prompt gained the
      # dilution handling rules block (~500 chars), user prompt
      # gained the "## Dilution context" section (~150 chars for
      # the :insufficient default used here).
      assert total < 5_000,
             "prompt is #{total} bytes total — review template length"
    end
  end

  describe "build/4 — dilution context (LON-117)" do
    test "system prompt carries dilution-handling rules" do
      [%{content: sys}, _] = build(article(), [], profile())

      assert sys =~ "Dilution risk handling"
      assert sys =~ "Active ATM"
      assert sys =~ "Recent S-1 filed within 14 days"
      assert sys =~ "Death-spiral convertible"
      assert sys =~ "Recent reverse split (within 90 days)"
      # The "no data → unknown, not clean" guard is the critical
      # default-safe rule. Make sure it's always present in the
      # system prompt, not just the user message.
      assert sys =~ "do NOT implicitly assume the stock is dilution-free"
    end

    test ":insufficient profile renders 'do NOT assume clean' branch in user message" do
      [_, %{content: usr}] =
        NewsAnalysis.build(
          article(),
          [],
          profile(),
          dilution_profile(%{data_completeness: :insufficient})
        )

      assert usr =~ "## Dilution context"
      assert usr =~ "No dilution-relevant filings found in last 180 days"
      assert usr =~ "do NOT assume clean dilution status"
    end

    test "active ATM renders remaining shares, pricing method and discount" do
      dp =
        dilution_profile(%{
          overall_severity: :high,
          overall_severity_reason: "ATM > 50% float (12M / 22M shares)",
          active_atm: %{
            remaining_shares: 12_000_000,
            pricing_method: :market_minus_pct,
            pricing_discount_pct: Decimal.new("5.0"),
            registered_at: ~U[2026-02-15 00:00:00.000000Z],
            used_to_date: 8_000_000,
            last_424b_filed_at: ~U[2026-04-30 00:00:00.000000Z],
            source_filing_ids: ["s3-id", "424b5-id"]
          },
          flags: [:large_overhang],
          last_filing_at: ~U[2026-04-30 00:00:00.000000Z],
          data_completeness: :high
        })

      [_, %{content: usr}] = NewsAnalysis.build(article(), [], profile(), dp)

      assert usr =~ "## Dilution context"
      assert usr =~ "Overall severity: HIGH"
      assert usr =~ "ATM > 50% float (12M / 22M shares)"
      assert usr =~ "Active ATM: 12M shares remaining at market_minus_pct (5.0%)"
      assert usr =~ "Flags: large_overhang"
    end

    test "pending S-1 renders dollar amount and filed date" do
      dp =
        dilution_profile(%{
          overall_severity: :high,
          overall_severity_reason: "Recent S-1 within 14d",
          pending_s1: %{
            deal_size_usd: Decimal.new("25000000"),
            filed_at: ~U[2026-05-01 00:00:00.000000Z],
            source_filing_id: "s1-id"
          },
          data_completeness: :partial
        })

      [_, %{content: usr}] = NewsAnalysis.build(article(), [], profile(), dp)

      assert usr =~ "Pending S-1: $25M filed on 2026-05-01"
    end

    test "warrant overhang renders shares and avg strike" do
      dp =
        dilution_profile(%{
          overall_severity: :medium,
          overall_severity_reason: "Warrant overhang",
          warrant_overhang: %{
            exercisable_shares: 8_000_000,
            avg_strike: Decimal.new("1.50"),
            source_filing_ids: ["w-id"]
          },
          data_completeness: :partial
        })

      [_, %{content: usr}] = NewsAnalysis.build(article(), [], profile(), dp)

      assert usr =~ "Warrant overhang: 8M shares @ avg strike $1.50"
    end

    test "recent reverse split renders ratio and execution date" do
      dp =
        dilution_profile(%{
          overall_severity: :medium,
          overall_severity_reason: "Recent reverse split",
          recent_reverse_split: %{
            ratio: "1:10",
            executed_at: ~U[2026-04-01 00:00:00.000000Z],
            source_filing_id: "rs-id"
          },
          data_completeness: :partial
        })

      [_, %{content: usr}] = NewsAnalysis.build(article(), [], profile(), dp)

      assert usr =~ "Recent reverse split: 1:10 on 2026-04-01"
    end

    test "insider selling line only appears when flag is true" do
      dp_with =
        dilution_profile(%{
          overall_severity: :high,
          overall_severity_reason: "Insider sold after filing",
          insider_selling_post_filing: true,
          data_completeness: :partial
        })

      dp_without =
        dilution_profile(%{
          overall_severity: :high,
          overall_severity_reason: "Some reason",
          insider_selling_post_filing: false,
          data_completeness: :partial
        })

      [_, %{content: with_content}] =
        NewsAnalysis.build(article(), [], profile(), dp_with)

      [_, %{content: without_content}] =
        NewsAnalysis.build(article(), [], profile(), dp_without)

      assert with_content =~ "Insider selling detected after recent dilution filing"
      refute without_content =~ "Insider selling detected"
    end

    test "flags 'none' renders when flags list is empty" do
      dp =
        dilution_profile(%{
          overall_severity: :low,
          overall_severity_reason: "Default low",
          flags: [],
          data_completeness: :partial
        })

      [_, %{content: usr}] = NewsAnalysis.build(article(), [], profile(), dp)

      assert usr =~ "Flags: none"
    end

    test "multiple flags joined with comma" do
      dp =
        dilution_profile(%{
          overall_severity: :critical,
          overall_severity_reason: "Death spiral + large overhang",
          flags: [:death_spiral_convertible, :large_overhang],
          data_completeness: :partial
        })

      [_, %{content: usr}] = NewsAnalysis.build(article(), [], profile(), dp)

      assert usr =~ "Flags: death_spiral_convertible, large_overhang"
    end
  end
end
