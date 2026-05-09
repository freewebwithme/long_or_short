defmodule LongOrShort.Filings.Extractor.RouterTest do
  @moduledoc """
  Tests for `LongOrShort.Filings.Extractor.Router`.

  Pure-function module. Doctests cover the four illustrative
  examples; this file exhaustively enumerates every filing type
  the policy speaks for, plus the config-override path.
  """

  use ExUnit.Case, async: false

  alias LongOrShort.AI.Providers.Claude
  alias LongOrShort.Filings.Extractor.Router

  doctest Router

  describe "tier_for/2 — cheap filings" do
    @cheap_types ~w(def14a _13d _13g)a

    test "every cheap-tier filing type returns :cheap" do
      for type <- @cheap_types do
        assert Router.tier_for(type) == :cheap, "expected :cheap for #{type}"
      end
    end
  end

  describe "tier_for/2 — complex filings" do
    @complex_types ~w(s1 s1a s3 s3a _424b1 _424b2 _424b3 _424b4 _424b5)a

    test "every complex-tier filing type returns :complex" do
      for type <- @complex_types do
        assert Router.tier_for(type) == :complex, "expected :complex for #{type}"
      end
    end
  end

  describe "tier_for/2 — 8-K subtype routing" do
    test "no subtype defaults to :cheap" do
      assert Router.tier_for(:_8k) == :cheap
      assert Router.tier_for(:_8k, nil) == :cheap
    end

    test "Item 3.02 (PIPE) routes to :cheap" do
      for subtype <- ["8-K Item 3.02", "Item 3.02", "Item 3.02 - Unregistered Equity"] do
        assert Router.tier_for(:_8k, subtype) == :cheap,
               "expected :cheap for subtype #{inspect(subtype)}"
      end
    end

    test "Item 1.01 (Material Definitive Agreement) routes to :complex" do
      for subtype <- ["8-K Item 1.01", "Item 1.01", "Item 1.01 — Material Agreement"] do
        assert Router.tier_for(:_8k, subtype) == :complex,
               "expected :complex for subtype #{inspect(subtype)}"
      end
    end

    test "other 8-K Items default to :cheap" do
      # Items like 5.07 (shareholder vote results), 8.01 (other events) —
      # not specifically routed, fall through the 8-K default.
      assert Router.tier_for(:_8k, "Item 5.07") == :cheap
      assert Router.tier_for(:_8k, "Item 8.01") == :cheap
    end
  end

  describe "model_for_tier/2 — explicit provider" do
    test "resolves cheap and complex tiers for Claude" do
      assert Router.model_for_tier(:cheap, Claude) == "claude-haiku-4-5-20251001"
      assert Router.model_for_tier(:complex, Claude) == "claude-sonnet-4-6"
    end
  end

  describe "model_for_tier/1 — uses configured :ai_provider" do
    setup do
      original_provider = Application.fetch_env!(:long_or_short, :ai_provider)
      Application.put_env(:long_or_short, :ai_provider, Claude)
      on_exit(fn -> Application.put_env(:long_or_short, :ai_provider, original_provider) end)
      :ok
    end

    test "falls back to the configured provider when none is passed" do
      assert Router.model_for_tier(:complex) == "claude-sonnet-4-6"
    end
  end

  describe "model_for_tier/2 — config override" do
    setup do
      original_models = Application.fetch_env!(:long_or_short, :filing_extraction_models)

      on_exit(fn ->
        Application.put_env(:long_or_short, :filing_extraction_models, original_models)
      end)

      :ok
    end

    test "respects an overridden model map" do
      Application.put_env(:long_or_short, :filing_extraction_models, %{
        Claude => %{cheap: "claude-haiku-9-9-9999", complex: "claude-sonnet-9-9"}
      })

      assert Router.model_for_tier(:cheap, Claude) == "claude-haiku-9-9-9999"
      assert Router.model_for_tier(:complex, Claude) == "claude-sonnet-9-9"
    end

    test "raises when the active provider has no entry — config bug must surface" do
      Application.put_env(:long_or_short, :filing_extraction_models, %{
        Claude => %{cheap: "x", complex: "y"}
      })

      assert_raise KeyError, fn ->
        Router.model_for_tier(:complex, SomeOtherProvider)
      end
    end
  end
end
