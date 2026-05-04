defmodule LongOrShort.AI.Prompts.MomentumAnalysisTest do
  use ExUnit.Case, async: true

  doctest LongOrShort.AI.Prompts.MomentumAnalysis

  alias LongOrShort.AI.Prompts.MomentumAnalysis

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

  describe "build/2 — message envelope" do
    test "returns [system, user]" do
      assert [%{role: "system", content: sys}, %{role: "user", content: usr}] =
               MomentumAnalysis.build(article())

      assert is_binary(sys)
      assert is_binary(usr)
    end

    test "system prompt establishes trader persona" do
      [%{content: sys}, _] = MomentumAnalysis.build(article())

      assert sys =~ "trader's analyst"
      assert sys =~ "$2–$10"
      assert sys =~ "spike-then-fade"
      assert sys =~ "record_momentum_analysis"
    end
  end

  describe "build/2 — user message rendering" do
    test "includes ticker, title, summary, source" do
      [_, %{content: content}] =
        MomentumAnalysis.build(
          article(%{
            title: "TSLA delivers record",
            summary: "Tesla beats expectations.",
            source: :benzinga,
            ticker: %{symbol: "TSLA"}
          })
        )

      assert content =~ "TSLA"
      assert content =~ "TSLA delivers record"
      assert content =~ "Tesla beats expectations."
      assert content =~ "benzinga"
    end

    test "renders (no summary) when summary is nil" do
      [_, %{content: content}] = MomentumAnalysis.build(article(%{summary: nil}))
      assert content =~ "(no summary)"
    end

    test "renders (no summary) when summary is empty string" do
      [_, %{content: content}] = MomentumAnalysis.build(article(%{summary: ""}))
      assert content =~ "(no summary)"
    end
  end

  describe "build/2 — past articles rendering" do
    test "shows placeholder when past_articles is empty" do
      [_, %{content: content}] = MomentumAnalysis.build(article(), [])
      assert content =~ "(no past articles in window)"
    end

    test "renders a single past article" do
      one = past(1, %{title: "Earlier news"})
      [_, %{content: content}] = MomentumAnalysis.build(article(), [one])

      assert content =~ "Earlier news"
      refute content =~ "(no past articles"
    end

    test "renders multiple past articles in given order" do
      pasts = Enum.map(1..3, &past/1)
      [_, %{content: content}] = MomentumAnalysis.build(article(), pasts)

      for a <- pasts do
        assert content =~ a.title
      end
    end
  end

  describe "build/2 — guideline content" do
    test "instructs the model to call the tool, not respond in text" do
      [_, %{content: content}] = MomentumAnalysis.build(article())

      assert content =~ "record_momentum_analysis"
      assert content =~ "Do not respond in plain text"
    end

    test "explains repetition counting convention" do
      [_, %{content: content}] = MomentumAnalysis.build(article())

      assert content =~ "Count the new article in repetition_count"
      assert content =~ "First occurrence = 1"
    end

    test "stays under sane token budget (~3.5k chars) with 5 past articles" do
      pasts = Enum.map(1..5, &past/1)
      [%{content: sys}, %{content: usr}] = MomentumAnalysis.build(article(), pasts)

      total = byte_size(sys) + byte_size(usr)

      assert total < 3_500,
             "prompt is #{total} bytes total — review template length"
    end
  end
end
