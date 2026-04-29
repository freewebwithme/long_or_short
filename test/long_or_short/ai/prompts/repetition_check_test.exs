defmodule LongOrShort.AI.Prompts.RepetitionCheckTest do
  use ExUnit.Case, async: true

  doctest LongOrShort.AI.Prompts.RepetitionCheck

  alias LongOrShort.AI.Prompts.RepetitionCheck

  defp new_article(overrides \\ %{}) do
    Map.merge(
      %{
        id: "00000000-0000-0000-0000-000000000001",
        title: "BTBD partners with Aero Velocity",
        summary: "Bit Digital announces a new aerospace partnership.",
        published_at: ~U[2026-04-20 12:00:00Z],
        ticker: %{symbol: "BTBD"}
      },
      overrides
    )
  end

  defp past_article(i, overrides \\ %{}) do
    Map.merge(
      %{
        id: "00000000-0000-0000-0000-00000000000#{i + 1}",
        title: "BTBD past announcement #{i}",
        published_at: DateTime.add(~U[2026-04-15 12:00:00Z], -i, :day)
      },
      overrides
    )
  end

  describe "build/2 — message envelope" do
    test "returns a single user message" do
      assert [%{role: "user", content: content}] =
               RepetitionCheck.build(new_article(), [])

      assert is_binary(content)
    end
  end

  describe "build/2 — new article rendering" do
    test "includes ticker symbol, title, and summary" do
      [%{content: content}] =
        RepetitionCheck.build(
          new_article(%{
            title: "TSLA delivers record",
            summary: "Tesla beats expectations.",
            ticker: %{symbol: "TSLA"}
          }),
          []
        )

      assert content =~ "TSLA"
      assert content =~ "TSLA delivers record"
      assert content =~ "Tesla beats expectations."
    end

    test "renders (no summary) when summary is nil" do
      [%{content: content}] =
        RepetitionCheck.build(new_article(%{summary: nil}), [])

      assert content =~ "(no summary)"
    end

    test "renders (no summary) when summary is empty string" do
      [%{content: content}] =
        RepetitionCheck.build(new_article(%{summary: ""}), [])

      assert content =~ "(no summary)"
    end

    test "includes the article id" do
      [%{content: content}] =
        RepetitionCheck.build(
          new_article(%{id: "abc-123"}),
          []
        )

      assert content =~ "abc-123"
    end
  end

  describe "build/2 — past articles rendering" do
    test "shows placeholder when past articles list is empty" do
      [%{content: content}] = RepetitionCheck.build(new_article(), [])

      assert content =~ "(no past articles in last 30 days)"
    end

    test "renders a single past article numbered 1" do
      past = past_article(1, %{title: "Earlier news"})
      [%{content: content}] = RepetitionCheck.build(new_article(), [past])

      assert content =~ "1. ID: #{past.id}"
      assert content =~ "Earlier news"
      refute content =~ "(no past articles"
    end

    test "renders multiple past articles in order" do
      pasts = Enum.map(1..3, &past_article/1)
      [%{content: content}] = RepetitionCheck.build(new_article(), pasts)

      for {a, i} <- Enum.with_index(pasts, 1) do
        assert content =~ "#{i}. ID: #{a.id}"
        assert content =~ a.title
      end
    end
  end

  describe "build/2 — guideline content" do
    test "instructs the model to call the tool, not respond in text" do
      [%{content: content}] = RepetitionCheck.build(new_article(), [])

      assert content =~ "report_repetition_analysis"
      assert content =~ "Do not respond in plain text"
    end

    test "specifies fatigue_level thresholds" do
      [%{content: content}] = RepetitionCheck.build(new_article(), [])

      assert content =~ "low: 1-2"
      assert content =~ "medium: 3"
      assert content =~ "high: 4+"
    end

    test "prompt stays under a sane token budget (~2k chars) with 5 past articles" do
      pasts = Enum.map(1..5, &past_article/1)
      [%{content: content}] = RepetitionCheck.build(new_article(), pasts)

      assert byte_size(content) < 2_500,
             "prompt is #{byte_size(content)} bytes — review template length"
    end
  end
end
