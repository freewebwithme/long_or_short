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

  describe "build/3 — message envelope" do
    test "returns [system, user]" do
      assert [%{role: "system", content: sys}, %{role: "user", content: usr}] =
               NewsAnalysis.build(article(), [], profile())

      assert is_binary(sys)
      assert is_binary(usr)
    end

    test "system prompt instructs the tool path" do
      [%{content: sys}, _] = NewsAnalysis.build(article(), [], profile())

      assert sys =~ "trader's analyst"
      assert sys =~ "record_news_analysis"
      assert sys =~ "respond in plain text"
    end
  end

  describe "build/3 — user message rendering" do
    test "includes ticker, title, summary, source" do
      [_, %{content: content}] =
        NewsAnalysis.build(
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
        NewsAnalysis.build(article(%{summary: nil}), [], profile())

      assert content =~ "(no summary)"
    end

    test "renders (no summary) when summary is empty string" do
      [_, %{content: content}] =
        NewsAnalysis.build(article(%{summary: ""}), [], profile())

      assert content =~ "(no summary)"
    end
  end

  describe "build/3 — past articles rendering" do
    test "shows placeholder when past_articles is empty" do
      [_, %{content: content}] = NewsAnalysis.build(article(), [], profile())
      assert content =~ "(no past articles in window)"
    end

    test "renders a single past article" do
      one = past(1, %{title: "Earlier news"})
      [_, %{content: content}] = NewsAnalysis.build(article(), [one], profile())

      assert content =~ "Earlier news"
      refute content =~ "(no past articles"
    end

    test "renders multiple past articles in given order" do
      pasts = Enum.map(1..3, &past/1)
      [_, %{content: content}] = NewsAnalysis.build(article(), pasts, profile())

      for a <- pasts do
        assert content =~ a.title
      end
    end
  end

  describe "build/3 — profile rendering (momentum_day default)" do
    test "renders persona intro for trading_style" do
      [%{content: sys}, _] = NewsAnalysis.build(article(), [], profile())
      assert sys =~ "small-cap momentum day trader"
    end

    test "renders structured profile lines (style, horizon, market caps, catalysts)" do
      [%{content: sys}, _] = NewsAnalysis.build(article(), [], profile())

      assert sys =~ "Style: momentum_day"
      assert sys =~ "Time horizon: intraday"
      assert sys =~ "Market cap focus: micro, small"
      assert sys =~ "partnership, fda, ma, contract_win"
    end

    test "renders price band when both min and max are set" do
      [%{content: sys}, _] = NewsAnalysis.build(article(), [], profile())
      assert sys =~ "$2"
      assert sys =~ "$10"
    end

    test "renders float ceiling formatted in M units" do
      [%{content: sys}, _] = NewsAnalysis.build(article(), [], profile())
      assert sys =~ "Float under 50M"
    end

    test "formats large floats in B units" do
      [%{content: sys}, _] =
        NewsAnalysis.build(article(), [], profile(%{float_max: 2_500_000_000}))

      assert sys =~ "Float under 2B"
    end
  end

  describe "build/3 — nullable style fields" do
    test "omits price band line when min is nil" do
      [%{content: sys}, _] =
        NewsAnalysis.build(article(), [], profile(%{price_min: nil}))

      refute sys =~ "Stocks priced"
    end

    test "omits price band line when max is nil" do
      [%{content: sys}, _] =
        NewsAnalysis.build(article(), [], profile(%{price_max: nil}))

      refute sys =~ "Stocks priced"
    end

    test "omits float line when float_max is nil" do
      [%{content: sys}, _] =
        NewsAnalysis.build(article(), [], profile(%{float_max: nil}))

      refute sys =~ "Float under"
    end

    test "renders 'any' for empty market_cap_focuses" do
      [%{content: sys}, _] =
        NewsAnalysis.build(article(), [], profile(%{market_cap_focuses: []}))

      assert sys =~ "Market cap focus: any"
    end

    test "renders 'any' for empty catalyst_preferences" do
      [%{content: sys}, _] =
        NewsAnalysis.build(article(), [], profile(%{catalyst_preferences: []}))

      assert sys =~ "Catalyst preferences: any"
    end
  end

  describe "build/3 — notes" do
    test "omits 'Additional notes:' block when notes is nil" do
      [%{content: sys}, _] =
        NewsAnalysis.build(article(), [], profile(%{notes: nil}))

      refute sys =~ "Additional notes:"
    end

    test "omits 'Additional notes:' block when notes is empty string" do
      [%{content: sys}, _] =
        NewsAnalysis.build(article(), [], profile(%{notes: ""}))

      refute sys =~ "Additional notes:"
    end

    test "renders notes when present" do
      [%{content: sys}, _] =
        NewsAnalysis.build(article(), [], profile(%{notes: "Avoid Friday afternoon trades."}))

      assert sys =~ "Additional notes:"
      assert sys =~ "Avoid Friday afternoon trades."
    end
  end

  describe "build/3 — style-variation (momentum vs swing)" do
    test "momentum_day persona uses scalp framing" do
      [%{content: sys}, _] =
        NewsAnalysis.build(article(), [], profile(%{trading_style: :momentum_day}))

      assert sys =~ "small-cap momentum day trader"
      assert sys =~ "5-minute scalp"
      assert sys =~ "fade risk"
    end

    test "swing persona uses multi-day continuation framing" do
      [%{content: sys}, _] =
        NewsAnalysis.build(article(), [], profile(%{trading_style: :swing}))

      assert sys =~ "swing trader"
      assert sys =~ "multi-day continuation"
      refute sys =~ "5-minute scalp"
    end

    test "large_cap_day persona references typical reaction range" do
      [%{content: sys}, _] =
        NewsAnalysis.build(article(), [], profile(%{trading_style: :large_cap_day}))

      assert sys =~ "large-cap day trader"
      assert sys =~ "typical reaction range"
      refute sys =~ "5-minute scalp"
    end

    test "position persona uses thesis framing" do
      [%{content: sys}, _] =
        NewsAnalysis.build(article(), [], profile(%{trading_style: :position}))

      assert sys =~ "position investor"
      assert sys =~ "long-term thesis"
      refute sys =~ "5-minute scalp"
    end

    test "options persona references implied volatility" do
      [%{content: sys}, _] =
        NewsAnalysis.build(article(), [], profile(%{trading_style: :options}))

      assert sys =~ "options trader"
      assert sys =~ "implied volatility"
      refute sys =~ "5-minute scalp"
    end
  end

  describe "build/3 — guideline content" do
    test "instructs the model to call the tool, not respond in text" do
      [_, %{content: content}] = NewsAnalysis.build(article(), [], profile())

      assert content =~ "record_news_analysis"
      assert content =~ "Do not respond in plain text"
    end

    test "explains repetition counting convention" do
      [_, %{content: content}] = NewsAnalysis.build(article(), [], profile())

      assert content =~ "Count the new article in repetition_count"
      assert content =~ "First occurrence = 1"
    end

    test "stays under sane token budget (~4k chars) with 5 past articles" do
      pasts = Enum.map(1..5, &past/1)

      [%{content: sys}, %{content: usr}] =
        NewsAnalysis.build(article(), pasts, profile())

      total = byte_size(sys) + byte_size(usr)

      assert total < 4_000,
             "prompt is #{total} bytes total — review template length"
    end
  end
end
