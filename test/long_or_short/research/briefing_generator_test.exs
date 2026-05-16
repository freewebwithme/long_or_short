defmodule LongOrShort.Research.BriefingGeneratorTest do
  @moduledoc """
  Tests for the sync briefing Generator (LON-172, PT-1).

  Uses an inline `TestProvider` that quacks like
  `Providers.Claude.call_with_search/2`. Same swap-config-pointer
  pattern Morning Brief uses (`async: false` because we mutate the
  `:research_briefing_provider` global).

  Covers:
    * cache miss → fresh generation persists + returns the row
    * cache hit (still-fresh row exists) → returns it without an LLM call
    * `unknown_symbol` short-circuit (no LLM call)
    * `no_trading_profile` short-circuit
    * telemetry emitted on success
  """

  use LongOrShort.DataCase, async: false

  import LongOrShort.AccountsFixtures
  import LongOrShort.TickersFixtures

  alias LongOrShort.Research.BriefingGenerator
  alias LongOrShort.Research.TickerBriefing

  # Inline fake provider. Per-process counter via `:counters` so we
  # can assert "exactly N LLM calls happened" without the MockProvider
  # ETS bag dedup quirks that bit us on LON-165.
  defmodule TestProvider do
    @counter_key {__MODULE__, :calls}
    @last_opts_key {__MODULE__, :last_opts}

    def init_counter do
      Process.put(@counter_key, :counters.new(1, []))
      Process.put(@last_opts_key, nil)
    end

    def call_count, do: :counters.get(Process.get(@counter_key), 1)
    def last_opts, do: Process.get(@last_opts_key)

    def call_with_search(_messages, opts) do
      :counters.add(Process.get(@counter_key), 1, 1)
      Process.put(@last_opts_key, opts)

      {:ok,
       %{
         text: "## TL;DR\n\nWatch — synthetic stub response.",
         citations: [%{idx: 1, url: "https://example.com", title: "Stub"}],
         usage: %{input_tokens: 200, output_tokens: 80},
         search_calls: 1
       }}
    end
  end

  setup do
    prior = Application.get_env(:long_or_short, :research_briefing_provider)
    Application.put_env(:long_or_short, :research_briefing_provider, TestProvider)
    TestProvider.init_counter()

    on_exit(fn ->
      Application.put_env(:long_or_short, :research_briefing_provider, prior)
    end)

    user = build_trader_user()
    _profile = build_trading_profile(%{user_id: user.id})

    {:ok, user_with_profile} =
      Ash.get(LongOrShort.Accounts.User, user.id, load: [:trading_profile], authorize?: false)

    {:ok, user: user_with_profile}
  end

  defp attach_success_telemetry do
    handler_id = "briefing-generator-success-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:long_or_short, :ticker_briefing, :generated],
      fn _e, m, meta, _c -> send(test_pid, {:telemetry_generated, m, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  describe "generate/3 — fresh path" do
    test "creates a TickerBriefing row + emits :generated telemetry", %{user: user} do
      attach_success_telemetry()
      ticker = build_ticker(%{symbol: "FRSH"})

      assert {:ok, %TickerBriefing{} = b} = BriefingGenerator.generate("FRSH", user)
      assert b.symbol == "FRSH"
      assert b.ticker_id == ticker.id
      assert b.generated_for_user_id == user.id
      assert b.narrative =~ "TL;DR"
      # TestProvider isn't a known provider module; the Generator's
      # `provider_label/1` fallback maps unknown providers to
      # `:anthropic` (the production default). This is fine for cost
      # attribution since test runs aren't billed.
      assert b.provider == :anthropic
      assert b.usage["input_tokens"] == 200

      assert_receive {:telemetry_generated, measurements, metadata}
      assert measurements.input_tokens == 200
      assert measurements.output_tokens == 80
      assert measurements.search_calls == 1
      assert metadata.ticker_id == ticker.id

      assert TestProvider.call_count() == 1
    end

    test "case-insensitive symbol — lowercase input resolves the upcased ticker", %{user: user} do
      _ticker = build_ticker(%{symbol: "LOW"})

      assert {:ok, %TickerBriefing{symbol: "LOW"}} = BriefingGenerator.generate("low", user)
    end
  end

  describe "generate/3 — cache hit path" do
    test "returns the cached row without an LLM call", %{user: user} do
      ticker = build_ticker(%{symbol: "CACHE"})

      # First call lands the row + 1 LLM call
      assert {:ok, %TickerBriefing{id: cached_id}} = BriefingGenerator.generate("CACHE", user)
      assert TestProvider.call_count() == 1

      # Second call within TTL — returns the same row, no extra LLM call
      assert {:ok, %TickerBriefing{id: ^cached_id}} = BriefingGenerator.generate("CACHE", user)
      assert TestProvider.call_count() == 1, "cache hit should not invoke the provider"

      _ = ticker
    end
  end

  describe "generate/3 — LON-179 cost + timeout knobs" do
    test "passes max_uses=3, max_tokens=2048, receive_timeout=180_000 by default", %{user: user} do
      _ticker = build_ticker(%{symbol: "KNOBS"})

      assert {:ok, _} = BriefingGenerator.generate("KNOBS", user)

      opts = TestProvider.last_opts()
      assert Keyword.get(opts, :max_uses) == 3
      assert Keyword.get(opts, :max_tokens) == 2048
      assert Keyword.get(opts, :receive_timeout) == 180_000
    end

    test "respects caller opt overrides", %{user: user} do
      _ticker = build_ticker(%{symbol: "OVR"})

      assert {:ok, _} =
               BriefingGenerator.generate("OVR", user,
                 max_searches: 1,
                 max_tokens: 512,
                 receive_timeout: 30_000
               )

      opts = TestProvider.last_opts()
      assert Keyword.get(opts, :max_uses) == 1
      assert Keyword.get(opts, :max_tokens) == 512
      assert Keyword.get(opts, :receive_timeout) == 30_000
    end

    test "resolves model from :research_briefing_model config", %{user: user} do
      prior = Application.get_env(:long_or_short, :research_briefing_model)
      Application.put_env(:long_or_short, :research_briefing_model, "claude-haiku-4-5-20251001")
      on_exit(fn -> Application.put_env(:long_or_short, :research_briefing_model, prior) end)

      _ticker = build_ticker(%{symbol: "HAIKU"})

      assert {:ok, briefing} = BriefingGenerator.generate("HAIKU", user)
      assert briefing.model == "claude-haiku-4-5-20251001"
      assert Keyword.get(TestProvider.last_opts(), :model) == "claude-haiku-4-5-20251001"
    end
  end

  describe "generate/3 — short-circuits before LLM call" do
    test "unknown symbol returns {:error, :unknown_symbol}", %{user: user} do
      assert {:error, :unknown_symbol} = BriefingGenerator.generate("NOTREAL", user)
      assert TestProvider.call_count() == 0
    end

    test "user without a TradingProfile returns {:error, :no_trading_profile}" do
      bare_user = build_trader_user()

      {:ok, loaded_bare} =
        Ash.get(LongOrShort.Accounts.User, bare_user.id,
          load: [:trading_profile],
          authorize?: false
        )

      _ticker = build_ticker(%{symbol: "NOPROF"})

      assert {:error, :no_trading_profile} = BriefingGenerator.generate("NOPROF", loaded_bare)
      assert TestProvider.call_count() == 0
    end
  end
end
