defmodule LongOrShortWeb.FormatTest do
  use ExUnit.Case, async: true
  doctest LongOrShortWeb.Format, except: [relative_time: 1]

  alias LongOrShortWeb.Format

  describe "price/1" do
    test "rounds to 2 decimal places" do
      assert Format.price(Decimal.new("215.4267")) == "215.43"
    end

    test "preserves trailing zeros for whole numbers" do
      assert Format.price(Decimal.new("100")) == "100.00"
    end

    test "nil returns empty string" do
      assert Format.price(nil) == ""
    end

    test "non-Decimal returns empty string" do
      assert Format.price("nope") == ""
      assert Format.price(42) == ""
    end
  end

  describe "relative_time/1" do
    test "less than a minute → just now" do
      assert Format.relative_time(DateTime.utc_now()) == "just now"
    end

    test "minutes" do
      dt = DateTime.add(DateTime.utc_now(), -300, :second)
      assert Format.relative_time(dt) == "5m ago"
    end

    test "hours" do
      dt = DateTime.add(DateTime.utc_now(), -7200, :second)
      assert Format.relative_time(dt) == "2h ago"
    end

    test "days" do
      dt = DateTime.add(DateTime.utc_now(), -86_400 * 3, :second)
      assert Format.relative_time(dt) == "3d ago"
    end
  end

  describe "shares/1" do
    test "billions" do
      assert Format.shares(16_350_000_000) == "16.35B"
    end

    test "millions" do
      assert Format.shares(50_000_000) == "50.00M"
    end

    test "below 1M shows raw" do
      assert Format.shares(500_000) == "500000"
    end

    test "nil returns em-dash" do
      assert Format.shares(nil) == "—"
    end
  end
end
