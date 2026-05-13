defmodule LongOrShortWeb.Live.ArticleDedupTest do
  use ExUnit.Case, async: true

  alias LongOrShortWeb.Live.ArticleDedup

  # Build minimal Article-shaped structs for unit testing.
  # No DataCase / DB — the dedup logic is purely in-memory.

  defmodule FakeTicker do
    defstruct [:symbol]
  end

  defmodule FakeArticle do
    defstruct [
      :id,
      :source,
      :external_id,
      :title,
      :published_at,
      :ticker
    ]
  end

  defp article(opts) do
    %FakeArticle{
      id: Keyword.get(opts, :id, "id-#{System.unique_integer([:positive])}"),
      source: Keyword.get(opts, :source, "alpaca"),
      external_id: Keyword.fetch!(opts, :external_id),
      title: Keyword.get(opts, :title, "headline"),
      published_at: Keyword.get(opts, :published_at, ~U[2026-05-12 12:00:00Z]),
      ticker:
        case Keyword.get(opts, :ticker) do
          nil -> nil
          sym -> %FakeTicker{symbol: sym}
        end
    }
  end

  describe "dedup/1" do
    test "collapses rows sharing (source, external_id) into one row with all ticker symbols" do
      rows = [
        article(id: "id-1", external_id: "ext-42", ticker: "OKLO"),
        article(id: "id-2", external_id: "ext-42", ticker: "TSLA"),
        article(id: "id-3", external_id: "ext-42", ticker: "SNDK")
      ]

      assert [row] = ArticleDedup.dedup(rows)
      assert row.id == "id-1"
      assert Enum.sort(row.ticker_symbols) == ["OKLO", "SNDK", "TSLA"]
    end

    test "keeps articles with different external_ids as separate rows" do
      rows = [
        article(id: "id-1", external_id: "ext-a", ticker: "A"),
        article(id: "id-2", external_id: "ext-b", ticker: "B")
      ]

      assert [_r1, _r2] = ArticleDedup.dedup(rows)
    end

    test "keeps articles with same external_id but different sources separate" do
      rows = [
        article(id: "id-1", source: "alpaca", external_id: "shared", ticker: "A"),
        article(id: "id-2", source: "finnhub", external_id: "shared", ticker: "B")
      ]

      assert [_r1, _r2] = ArticleDedup.dedup(rows)
    end

    test "sorts results by published_at desc, NOT by id desc (LON-155)" do
      # Intentional: id ascending order doesn't match published_at
      # ordering. dedup must surface freshest publish first.
      rows = [
        article(
          id: "id-aaa",
          external_id: "ext-old-pub",
          ticker: "OLD",
          published_at: ~U[2026-05-12 09:00:00Z]
        ),
        article(
          id: "id-bbb",
          external_id: "ext-new-pub",
          ticker: "NEW",
          published_at: ~U[2026-05-12 12:00:00Z]
        )
      ]

      assert [first, second] = ArticleDedup.dedup(rows)
      assert first.ticker_symbols == ["NEW"]
      assert second.ticker_symbols == ["OLD"]
    end

    test "an article with no ticker contributes no symbol but is still present" do
      rows = [article(id: "id-1", external_id: "ext-1", ticker: nil)]
      assert [row] = ArticleDedup.dedup(rows)
      assert row.ticker_symbols == []
    end
  end

  describe "to_row/1" do
    test "wraps a single article into the same presentation shape" do
      a = article(id: "id-x", external_id: "ext-x", ticker: "FOO")
      row = ArticleDedup.to_row(a)

      assert row.id == "id-x"
      assert row.ticker_symbols == ["FOO"]
      refute Map.has_key?(row, :__struct__)
    end
  end
end
