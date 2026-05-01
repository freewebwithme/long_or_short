defmodule LongOrShort.Tickers.WatchlistTest do
  use ExUnit.Case, async: true

  alias LongOrShort.Tickers.Watchlist

  describe "parse/1" do
    test "comments stripped" do
      assert Watchlist.parse("# comment\nAAPL\n") == ["AAPL"]
    end

    test "blank lines stripped" do
      assert Watchlist.parse("\nAAPL\n\nMSFT\n") == ["AAPL", "MSFT"]
    end

    test "lowercase upcased" do
      assert Watchlist.parse("aapl\nMsft\n") == ["AAPL", "MSFT"]
    end

    test "duplicates removed (case-insensitive)" do
      assert Watchlist.parse("AAPL\naapl\nMSFT\n") == ["AAPL", "MSFT"]
    end

    test "extra whitespace trimmed" do
      assert Watchlist.parse("  AAPL  \n\tMSFT\n") == ["AAPL", "MSFT"]
    end

    test "empty input" do
      assert Watchlist.parse("") == []
    end

    test "only comments and blanks → empty" do
      assert Watchlist.parse("# foo\n# bar\n\n") == []
    end
  end

  describe "symbols/0 with override" do
    setup do
      previous = Application.get_env(:long_or_short, :watchlist_override)

      on_exit(fn ->
        if is_nil(previous) do
          Application.delete_env(:long_or_short, :watchlist_override)
        else
          Application.put_env(:long_or_short, :watchlist_override, previous)
        end
      end)

      :ok
    end

    test "returns the override list, normalized" do
      Application.put_env(:long_or_short, :watchlist_override, ~w(aapl AAPL tsla))
      assert Watchlist.symbols() == ["AAPL", "TSLA"]
    end

    test "empty override list returns []" do
      Application.put_env(:long_or_short, :watchlist_override, [])
      assert Watchlist.symbols() == []
    end
  end
end
