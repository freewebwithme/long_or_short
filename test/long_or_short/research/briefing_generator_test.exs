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

  # ── LON-174: TTL + force + cache-hit telemetry ──────────────────

  describe "generate/3 — LON-174 force refresh" do
    test "force: true bypasses an otherwise-fresh cache and re-invokes the provider", %{
      user: user
    } do
      _ticker = build_ticker(%{symbol: "FORCE"})

      # First call lands a fresh cached row.
      assert {:ok, %TickerBriefing{} = first} = BriefingGenerator.generate("FORCE", user)
      assert TestProvider.call_count() == 1

      # `generated_at` is now() — rate limit will block force within 60s.
      # Backdate the row so the force path proceeds.
      backdate_generated_at(first, 120)

      assert {:ok, %TickerBriefing{} = second} =
               BriefingGenerator.generate("FORCE", user, force: true)

      assert TestProvider.call_count() == 2, "force=true must hit the provider"
      # Upsert identity is `(ticker_id, user_id)` — same row, new generated_at
      assert second.id == first.id
      assert DateTime.compare(second.generated_at, first.generated_at) == :gt
    end

    test "force: true within the 60s rate window returns {:rate_limited_refresh, n}", %{
      user: user
    } do
      _ticker = build_ticker(%{symbol: "RATE"})

      assert {:ok, _} = BriefingGenerator.generate("RATE", user)
      assert TestProvider.call_count() == 1

      # Immediate refresh — row's generated_at is well within 60s.
      assert {:error, {:rate_limited_refresh, seconds_remaining}} =
               BriefingGenerator.generate("RATE", user, force: true)

      assert is_integer(seconds_remaining)
      assert seconds_remaining > 0 and seconds_remaining <= 60
      assert TestProvider.call_count() == 1, "rate-limited force must not hit the provider"
    end
  end

  describe "generate/3 — LON-174 cache-hit telemetry" do
    test "served_from_cache telemetry fires on a DB cache hit", %{user: user} do
      handler_id = "briefing-cache-hit-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:long_or_short, :ticker_briefing, :served_from_cache],
        fn _e, m, meta, _c -> send(test_pid, {:telemetry_cache_hit, m, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      ticker = build_ticker(%{symbol: "HITTEL"})

      # 1st call: cache miss — no cache-hit telemetry expected
      assert {:ok, _} = BriefingGenerator.generate("HITTEL", user)
      refute_received {:telemetry_cache_hit, _, _}

      # 2nd call: cache hit — telemetry fires once
      assert {:ok, _} = BriefingGenerator.generate("HITTEL", user)
      assert_receive {:telemetry_cache_hit, %{count: 1}, %{ticker_id: tid, user_id: uid}}
      assert tid == ticker.id
      assert uid == user.id
    end
  end

  describe "generate/3 — LON-174 bucketed TTL" do
    test "cached_until honors the BriefingFreshness policy for the supplied et_now", %{
      user: user
    } do
      _ticker = build_ticker(%{symbol: "TTL"})

      # 12:00 UTC on a weekday → 08:00 ET (EDT, premarket window, 5min TTL)
      premarket_now = ~U[2026-05-13 12:00:00Z]

      assert {:ok, briefing} = BriefingGenerator.generate("TTL", user, et_now: premarket_now)

      # cached_until = et_now + 5min = 12:05:00 UTC
      expected = DateTime.add(premarket_now, 5 * 60, :second)
      # Allow a 2-second window for the upsert round-trip
      assert DateTime.diff(briefing.cached_until, expected, :second) |> abs() <= 2
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────

  # Rewinds `generated_at` so the force path can proceed past the
  # 60s rate-limit. Uses the default :update action with
  # `authorize?: false` (default-deny policies block real callers).
  defp backdate_generated_at(%TickerBriefing{} = b, seconds_ago) do
    new_ts = DateTime.add(DateTime.utc_now(), -seconds_ago, :second)

    b
    |> Ash.Changeset.for_update(:update, %{})
    |> Ash.Changeset.force_change_attribute(:generated_at, new_ts)
    |> Ash.update!(authorize?: false)
  end

  # ── LON-185: playbook snapshot ──────────────────────────────────

  describe "generate/3 — playbook snapshot (LON-185)" do
    test "user with no Playbook → snapshot is empty map, briefing generates normally",
         %{user: user} do
      _ticker = build_ticker(%{symbol: "NOPB"})

      assert {:ok, briefing} = BriefingGenerator.generate("NOPB", user)
      assert briefing.playbook_snapshot == %{}

      # The prompt the LLM saw should NOT mention "Trader's Playbook"
      # — empty-string degradation contract.
      refute Keyword.get(TestProvider.last_opts(), :model) == nil
      # (The full prompt content isn't passed through to opts; the
      # prompt-injection assertion lives in ticker_briefing_test.exs.
      # Here we just confirm the snapshot persisted is empty.)
    end

    test "user with active Playbook → snapshot freezes rendered + structured shape",
         %{user: user} do
      # Seed two active playbooks for this user
      {:ok, _rules} =
        LongOrShort.Trading.create_playbook_version(
          user.id,
          :rules,
          "Daily rules",
          [%{text: "Daily max loss $160"}, %{text: "No revenge trades"}],
          authorize?: false
        )

      {:ok, _setup} =
        LongOrShort.Trading.create_playbook_version(
          user.id,
          :setup,
          "Long setup",
          [%{text: "Price $2-$10"}, %{text: "Above VWAP"}],
          authorize?: false
        )

      _ticker = build_ticker(%{symbol: "PBSNAP"})

      assert {:ok, briefing} = BriefingGenerator.generate("PBSNAP", user)

      snapshot = briefing.playbook_snapshot

      # Snapshot has the two top-level keys (jsonb round-trip → string keys)
      assert is_binary(snapshot["rendered"])
      assert snapshot["rendered"] =~ "Trader's Playbook"
      assert snapshot["rendered"] =~ "Daily max loss $160"
      assert snapshot["rendered"] =~ "**Long setup**"

      # Structured playbook list — sorted by [kind, name] from list_active_playbooks
      assert [rules_pb, setup_pb] = snapshot["playbooks"]

      assert rules_pb["kind"] == "rules"
      assert rules_pb["name"] == "Daily rules"
      assert rules_pb["version"] == 1
      assert length(rules_pb["items"]) == 2

      # Each item carries its UUID (the keystone for LON-176 retrospection)
      [item1, _item2] = rules_pb["items"]
      assert is_binary(item1["id"])
      assert byte_size(item1["id"]) == 36
      assert item1["text"] == "Daily max loss $160"

      assert setup_pb["kind"] == "setup"
      assert setup_pb["name"] == "Long setup"
    end

    test "snapshot is refreshed on re-generation via force (not frozen from first call)",
         %{user: user} do
      # v1 playbook
      {:ok, _} =
        LongOrShort.Trading.create_playbook_version(
          user.id,
          :rules,
          "Daily rules",
          [%{text: "v1 rule"}],
          authorize?: false
        )

      _ticker = build_ticker(%{symbol: "REGEN"})

      assert {:ok, first} = BriefingGenerator.generate("REGEN", user)
      assert hd(first.playbook_snapshot["playbooks"])["items"]
             |> List.first()
             |> Map.get("text") == "v1 rule"

      # Trader edits the playbook between calls
      {:ok, _} =
        LongOrShort.Trading.create_playbook_version(
          user.id,
          :rules,
          "Daily rules",
          [%{text: "v2 rule — refined"}],
          authorize?: false
        )

      # Backdate to clear LON-174 60s rate-limit
      backdate_generated_at(first, 120)

      assert {:ok, second} = BriefingGenerator.generate("REGEN", user, force: true)

      # Same row (unique_ticker_user_active identity), refreshed snapshot
      assert second.id == first.id
      assert hd(second.playbook_snapshot["playbooks"])["items"]
             |> List.first()
             |> Map.get("text") == "v2 rule — refined"
    end
  end
end
