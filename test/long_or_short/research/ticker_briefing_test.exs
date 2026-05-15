defmodule LongOrShort.Research.TickerBriefingTest do
  @moduledoc """
  Tests for the `TickerBriefing` Ash resource (LON-172, PT-1).

  Covers action contracts (create / upsert / get_latest_for / by_user)
  and the `cached_until > now()` cache-window filter.

  Policy coverage is in `describe "policies"` blocks at the end; all
  other tests use `authorize?: false` per project convention.
  """

  use LongOrShort.DataCase, async: false

  import LongOrShort.AccountsFixtures
  import LongOrShort.TickersFixtures

  alias LongOrShort.Research
  alias LongOrShort.Research.TickerBriefing

  defp valid_attrs(overrides \\ %{}) do
    ticker = Map.get_lazy(overrides, :ticker, fn -> build_ticker(%{symbol: "FOO"}) end)
    user = Map.get_lazy(overrides, :user, fn -> build_trader_user() end)

    base = %{
      symbol: ticker.symbol,
      narrative: "## TL;DR\n\nWatch — thin catalyst.",
      structured: %{},
      citations: [],
      provider: :mock,
      model: "mock-sonnet",
      usage: %{"input_tokens" => 100, "output_tokens" => 50},
      cached_until: DateTime.add(DateTime.utc_now(), 600, :second),
      trading_profile_snapshot: %{"trading_style" => "momentum_day"},
      ticker_id: ticker.id,
      generated_for_user_id: user.id
    }

    Map.merge(base, Map.drop(overrides, [:ticker, :user]))
  end

  describe "create / upsert" do
    test ":create persists a row and sets generated_at" do
      attrs = valid_attrs()

      assert {:ok, %TickerBriefing{} = b} = Research.create_ticker_briefing(attrs, authorize?: false)
      assert b.symbol == "FOO"
      assert b.narrative =~ "TL;DR"
      assert b.generated_at != nil
      assert DateTime.compare(b.cached_until, DateTime.utc_now()) == :gt
    end

    test ":upsert overwrites the existing row for the same (ticker, user)" do
      ticker = build_ticker(%{symbol: "DBL"})
      user = build_trader_user()
      attrs = valid_attrs(%{ticker: ticker, user: user, narrative: "first"})

      {:ok, first} = Research.upsert_ticker_briefing(attrs, authorize?: false)

      {:ok, second} =
        Research.upsert_ticker_briefing(
          Map.put(attrs, :narrative, "second"),
          authorize?: false
        )

      # Same row id — upsert overwrote, didn't insert
      assert first.id == second.id
      assert second.narrative == "second"
      assert DateTime.compare(second.generated_at, first.generated_at) != :lt
    end
  end

  describe "get_latest_briefing_for/3 — cache window" do
    test "returns the fresh briefing when cached_until > now" do
      ticker = build_ticker(%{symbol: "FRESH"})
      user = build_trader_user()
      attrs = valid_attrs(%{ticker: ticker, user: user})

      {:ok, briefing} = Research.upsert_ticker_briefing(attrs, authorize?: false)

      assert {:ok, %TickerBriefing{} = found} =
               Research.get_latest_briefing_for(ticker.symbol, user.id, authorize?: false)

      assert found.id == briefing.id
    end

    test "returns nil when cached_until is in the past" do
      ticker = build_ticker(%{symbol: "STALE"})
      user = build_trader_user()

      expired_attrs =
        valid_attrs(%{
          ticker: ticker,
          user: user,
          cached_until: DateTime.add(DateTime.utc_now(), -60, :second)
        })

      {:ok, _stale} = Research.upsert_ticker_briefing(expired_attrs, authorize?: false)

      assert {:ok, nil} =
               Research.get_latest_briefing_for(ticker.symbol, user.id, authorize?: false)
    end

    test "scoped to (symbol, user_id) — another user's briefing doesn't leak" do
      ticker = build_ticker(%{symbol: "SCOPED"})
      user_a = build_trader_user()
      user_b = build_trader_user()

      {:ok, _} =
        Research.upsert_ticker_briefing(
          valid_attrs(%{ticker: ticker, user: user_a}),
          authorize?: false
        )

      assert {:ok, nil} =
               Research.get_latest_briefing_for(ticker.symbol, user_b.id, authorize?: false)
    end
  end

  describe "list_recent_briefings_by_user/1" do
    test "returns the user's briefings, newest first" do
      user = build_trader_user()
      t1 = build_ticker(%{symbol: "FIRST"})
      t2 = build_ticker(%{symbol: "SECOND"})

      {:ok, _} = Research.upsert_ticker_briefing(valid_attrs(%{ticker: t1, user: user}), authorize?: false)
      {:ok, _} = Research.upsert_ticker_briefing(valid_attrs(%{ticker: t2, user: user}), authorize?: false)

      # The action declares `pagination required?: false`, so without
      # a `:page` opt it returns a plain list (not Keyset-wrapped).
      assert {:ok, [latest, earliest]} =
               Research.list_recent_briefings_by_user(user.id, authorize?: false)

      assert latest.symbol == "SECOND"
      assert earliest.symbol == "FIRST"
    end

    test "does not include another user's briefings" do
      user_a = build_trader_user()
      user_b = build_trader_user()
      ticker = build_ticker(%{symbol: "ABC"})

      {:ok, _} = Research.upsert_ticker_briefing(valid_attrs(%{ticker: ticker, user: user_a}), authorize?: false)

      assert {:ok, []} =
               Research.list_recent_briefings_by_user(user_b.id, authorize?: false)
    end
  end

  describe "policies" do
    test "trader can read own briefing but not another trader's" do
      user_a = build_trader_user()
      user_b = build_trader_user()
      ticker = build_ticker(%{symbol: "POL"})

      {:ok, briefing} =
        Research.upsert_ticker_briefing(
          valid_attrs(%{ticker: ticker, user: user_a}),
          authorize?: false
        )

      # Owner reads — allowed
      assert {:ok, _} = Ash.get(TickerBriefing, briefing.id, actor: user_a)

      # Non-owner reads — Ash applies the actor-scope as a filter, so
      # the row is invisible to user_b. Returns NotFound (wrapped in
      # Invalid), not Forbidden — that's the documented Ash behavior
      # for filter-based read policies.
      assert {:error, %Ash.Error.Invalid{} = err} =
               Ash.get(TickerBriefing, briefing.id, actor: user_b)

      assert Enum.any?(err.errors, fn e -> e.__struct__ == Ash.Error.Query.NotFound end)
    end
  end
end
