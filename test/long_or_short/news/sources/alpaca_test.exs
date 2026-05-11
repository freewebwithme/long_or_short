defmodule LongOrShort.News.Sources.AlpacaTest do
  use ExUnit.Case, async: true

  alias LongOrShort.News.Sources.Alpaca

  describe "parse_response/1" do
    test "single-symbol article maps to one attrs map" do
      raw = %{
        "id" => 12345,
        "headline" => "Apple announces new AI initiative",
        "summary" => "Apple committed to AI investment for 2026.",
        "url" => "https://example.com/apple-ai",
        "symbols" => ["AAPL"],
        "source" => "Benzinga",
        "created_at" => "2026-05-11T12:00:00Z",
        "updated_at" => "2026-05-11T12:05:00Z",
        "content" => "<p>Full article content...</p>",
        "author" => "Jane Doe"
      }

      assert {:ok, [attrs]} = Alpaca.parse_response(raw)
      assert attrs.source == :alpaca
      assert attrs.external_id == "12345"
      assert attrs.symbol == "AAPL"
      assert attrs.title == "Apple announces new AI initiative"
      assert attrs.summary == "Apple committed to AI investment for 2026."
      assert attrs.url == "https://example.com/apple-ai"
      assert attrs.raw_category == "Benzinga"
      assert attrs.sentiment == :unknown
      assert attrs.published_at == ~U[2026-05-11 12:00:00Z]
    end

    test "multi-symbol article fans out into one attrs map per ticker" do
      raw = %{
        "id" => 67890,
        "headline" => "Tech sector rallies on Fed dovish signal",
        "symbols" => ["AAPL", "MSFT", "GOOG"],
        "source" => "Benzinga",
        "created_at" => "2026-05-11T13:30:00Z"
      }

      assert {:ok, attrs_list} = Alpaca.parse_response(raw)
      assert length(attrs_list) == 3

      assert Enum.map(attrs_list, & &1.symbol) == ["AAPL", "MSFT", "GOOG"]

      # Shared fields are identical across the fan-out — same article,
      # different tickers.
      Enum.each(attrs_list, fn attrs ->
        assert attrs.source == :alpaca
        assert attrs.external_id == "67890"
        assert attrs.title == "Tech sector rallies on Fed dovish signal"
        assert attrs.raw_category == "Benzinga"
        assert attrs.published_at == ~U[2026-05-11 13:30:00Z]
      end)
    end

    test "empty-string symbols inside the array are filtered out" do
      raw = %{
        "id" => 1,
        "headline" => "Mixed-symbol article",
        "symbols" => ["AAPL", "", "MSFT"],
        "created_at" => "2026-05-11T12:00:00Z"
      }

      assert {:ok, attrs_list} = Alpaca.parse_response(raw)
      assert Enum.map(attrs_list, & &1.symbol) == ["AAPL", "MSFT"]
    end

    test "missing id returns :missing_required_fields" do
      raw = %{
        "headline" => "Headline only",
        "symbols" => ["AAPL"],
        "created_at" => "2026-05-11T12:00:00Z"
      }

      assert {:error, :missing_required_fields} = Alpaca.parse_response(raw)
    end

    test "missing headline returns :missing_required_fields" do
      raw = %{
        "id" => 1,
        "symbols" => ["AAPL"],
        "created_at" => "2026-05-11T12:00:00Z"
      }

      assert {:error, :missing_required_fields} = Alpaca.parse_response(raw)
    end

    test "empty symbols array returns :missing_required_fields" do
      # A market-wide news item with no ticker tags is not actionable
      # — we drop it rather than ingesting an Article-less row.
      raw = %{
        "id" => 1,
        "headline" => "Generic market commentary",
        "symbols" => [],
        "created_at" => "2026-05-11T12:00:00Z"
      }

      assert {:error, :missing_required_fields} = Alpaca.parse_response(raw)
    end

    test "missing created_at returns :missing_required_fields" do
      raw = %{
        "id" => 1,
        "headline" => "Anything",
        "symbols" => ["AAPL"]
      }

      assert {:error, :missing_required_fields} = Alpaca.parse_response(raw)
    end

    test "invalid created_at format returns :missing_required_fields" do
      raw = %{
        "id" => 1,
        "headline" => "Anything",
        "symbols" => ["AAPL"],
        "created_at" => "not-a-date"
      }

      assert {:error, :missing_required_fields} = Alpaca.parse_response(raw)
    end

    test "missing optional fields default to nil (summary, url, source)" do
      raw = %{
        "id" => 1,
        "headline" => "Minimal payload",
        "symbols" => ["AAPL"],
        "created_at" => "2026-05-11T12:00:00Z"
      }

      assert {:ok, [attrs]} = Alpaca.parse_response(raw)
      assert is_nil(attrs.summary)
      assert is_nil(attrs.url)
      assert is_nil(attrs.raw_category)
      assert attrs.sentiment == :unknown
    end

    test "non-binary headline returns :missing_required_fields" do
      raw = %{
        "id" => 1,
        "headline" => 12345,
        "symbols" => ["AAPL"],
        "created_at" => "2026-05-11T12:00:00Z"
      }

      assert {:error, :missing_required_fields} = Alpaca.parse_response(raw)
    end
  end

  describe "behaviour callbacks" do
    test "source_name/0 returns :alpaca" do
      assert Alpaca.source_name() == :alpaca
    end

    test "poll_interval_ms/0 returns 60_000" do
      assert Alpaca.poll_interval_ms() == 60_000
    end
  end
end
