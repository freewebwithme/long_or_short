defmodule LongOrShort.Tickers.TrackedTest do
  use ExUnit.Case, async: true

  alias LongOrShort.Tickers.Tracked

  describe "parse/1" do
    test "comments stripped" do
      assert Tracked.parse("# comment\nAAPL\n") == ["AAPL"]
    end

    test "blank lines stripped" do
      assert Tracked.parse("\nAAPL\n\nMSFT\n") == ["AAPL", "MSFT"]
    end

    test "lowercase upcased" do
      assert Tracked.parse("aapl\nMsft\n") == ["AAPL", "MSFT"]
    end

    test "duplicates removed (case-insensitive)" do
      assert Tracked.parse("AAPL\naapl\nMSFT\n") == ["AAPL", "MSFT"]
    end

    test "extra whitespace trimmed" do
      assert Tracked.parse("  AAPL  \n\tMSFT\n") == ["AAPL", "MSFT"]
    end

    test "empty input" do
      assert Tracked.parse("") == []
    end

    test "only comments and blanks → empty" do
      assert Tracked.parse("# foo\n# bar\n\n") == []
    end
  end

  describe "symbols/0 with override" do
    setup do
      previous = Application.get_env(:long_or_short, :tracked_tickers_override)

      on_exit(fn ->
        if is_nil(previous) do
          Application.delete_env(:long_or_short, :tracked_tickers_override)
        else
          Application.put_env(:long_or_short, :tracked_tickers_override, previous)
        end
      end)

      :ok
    end

    test "returns the override list, normalized" do
      Application.put_env(:long_or_short, :tracked_tickers_override, ~w(aapl AAPL tsla))
      assert Tracked.symbols() == ["AAPL", "TSLA"]
    end

    test "empty override list returns []" do
      Application.put_env(:long_or_short, :tracked_tickers_override, [])
      assert Tracked.symbols() == []
    end
  end
end
