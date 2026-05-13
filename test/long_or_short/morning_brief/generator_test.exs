defmodule LongOrShort.MorningBrief.GeneratorTest do
  # `async: false` — we swap `Application.put_env(:morning_brief_provider, ...)`
  # which is global. Per-test isolation is via Process-dict stubs in TestProvider.
  use LongOrShort.DataCase, async: false

  alias LongOrShort.Analysis
  alias LongOrShort.MorningBrief.Generator

  # ── Inline test provider ──────────────────────────────────────────
  #
  # Quacks like `Providers.Claude.call_with_search/2`. Per-process
  # response stubs via `Process.put(:gen_test_response, ...)`. Records
  # the call by sending `{:provider_called, messages, opts}` to the
  # pid stashed in `:gen_test_pid` (typically the test process).

  defmodule TestProvider do
    @moduledoc false

    def call_with_search(messages, opts) do
      if pid = Process.get(:gen_test_pid) do
        send(pid, {:provider_called, messages, opts})
      end

      case Process.get(:gen_test_response) do
        nil ->
          raise "TestProvider: no response stubbed — set :gen_test_response in Process dict"

        response ->
          response
      end
    end
  end

  setup do
    prior = Application.get_env(:long_or_short, :morning_brief_provider)
    Application.put_env(:long_or_short, :morning_brief_provider, TestProvider)
    on_exit(fn -> Application.put_env(:long_or_short, :morning_brief_provider, prior) end)

    Process.put(:gen_test_pid, self())
    Process.delete(:gen_test_response)

    :ok
  end

  # ── Telemetry collector ──────────────────────────────────────────
  #
  # Attaches a per-test handler that forwards events to the test pid.
  # Detach in `on_exit` so handlers don't leak across tests.

  defp attach_telemetry(event_suffix) do
    handler_id = "gen-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:long_or_short, :morning_brief, event_suffix],
      fn _event, measurements, metadata, _config ->
        send(self(), {:telemetry, event_suffix, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok
  end

  # ── Helpers ──────────────────────────────────────────────────────

  defp ok_response(overrides \\ %{}) do
    Map.merge(
      %{
        text: "Test brief — 시장 약세 [1].",
        citations: [
          %{
            idx: 1,
            url: "https://www.cnbc.com/x",
            title: "CNBC X",
            source: "cnbc.com",
            cited_text: "snip",
            accessed_at: DateTime.utc_now()
          }
        ],
        usage: %{input_tokens: 30_000, output_tokens: 800, web_search_requests: 3},
        search_calls: 3
      },
      overrides
    )
  end

  describe "generate_for_bucket/2 — happy path" do
    test "upserts a Digest with content, citations, usage, and provider metadata" do
      response = ok_response()
      Process.put(:gen_test_response, {:ok, response})

      et_now = ~U[2026-05-12 12:45:00.000000Z] |> DateTime.shift_zone!("America/New_York")

      assert {:ok, digest} =
               Generator.generate_for_bucket(:premarket, et_now: et_now, model: "claude-haiku-4-5-20251001")

      assert digest.bucket == :premarket
      # ET 08:45 on 2026-05-12 — bucket_date is the ET calendar date
      assert digest.bucket_date == ~D[2026-05-12]
      assert digest.content =~ "시장 약세"
      assert digest.llm_provider == :anthropic
      assert digest.llm_model == "claude-haiku-4-5-20251001"
      assert digest.search_calls == 3
      assert digest.input_tokens == 30_000
      assert digest.output_tokens == 800

      [c1] = digest.citations
      assert c1["url"] == "https://www.cnbc.com/x"
      assert c1["source"] == "cnbc.com"
    end

    test "threads model + max_searches into provider opts" do
      Process.put(:gen_test_response, {:ok, ok_response()})

      Generator.generate_for_bucket(:overnight,
        model: "claude-sonnet-4-6",
        max_searches: 2
      )

      assert_receive {:provider_called, _messages, opts}
      assert Keyword.get(opts, :model) == "claude-sonnet-4-6"
      assert Keyword.get(opts, :max_uses) == 2
    end

    test "uses bucket-specific system prompt" do
      Process.put(:gen_test_response, {:ok, ok_response()})

      Generator.generate_for_bucket(:after_open)

      assert_receive {:provider_called, messages, _opts}
      [system, _user] = messages
      assert system.role == "system"
      # The after_open bucket's focus markers
      assert system.content =~ "after_open"
      assert system.content =~ "10:00 ET"
    end

    test "raw_response is JSON-sanitized (atom keys → string keys)" do
      Process.put(:gen_test_response, {:ok, ok_response()})

      {:ok, digest} = Generator.generate_for_bucket(:premarket)

      # `Jason.encode! |> decode!` round-trip strips atoms — every key
      # in raw_response is a string after persistence.
      assert is_map(digest.raw_response)
      assert Enum.all?(Map.keys(digest.raw_response), &is_binary/1)
      assert digest.raw_response["text"] =~ "시장 약세"
      assert digest.raw_response["search_calls"] == 3
    end
  end

  describe "generate_for_bucket/2 — error paths" do
    test "provider error returns {:error, reason} and emits :generation_failed telemetry" do
      attach_telemetry(:generation_failed)
      Process.put(:gen_test_response, {:error, {:rate_limited, 30}})

      assert {:error, {:rate_limited, 30}} = Generator.generate_for_bucket(:premarket)

      assert_receive {:telemetry, :generation_failed, measurements, metadata}
      assert is_integer(measurements.duration_ms)
      assert metadata.bucket == :premarket
      assert metadata.reason == {:rate_limited, 30}
    end

    test "no Digest is created when the provider fails" do
      Process.put(:gen_test_response, {:error, :network_error})
      assert {:error, :network_error} = Generator.generate_for_bucket(:premarket)

      # Sanity: no row landed for today's :premarket slot
      et_today = DateTime.utc_now() |> DateTime.shift_zone!("America/New_York") |> DateTime.to_date()
      assert {:ok, nil} = Analysis.get_digest(et_today, :premarket, authorize?: false)
    end
  end

  describe "generate_for_bucket/2 — telemetry" do
    test "emits :generated event with token + search measurements on success" do
      attach_telemetry(:generated)

      Process.put(
        :gen_test_response,
        {:ok, ok_response(%{usage: %{input_tokens: 1000, output_tokens: 200, web_search_requests: 4}, search_calls: 4})}
      )

      Generator.generate_for_bucket(:overnight)

      assert_receive {:telemetry, :generated, measurements, metadata}
      assert measurements.input_tokens == 1000
      assert measurements.output_tokens == 200
      assert measurements.search_calls == 4
      assert is_integer(measurements.duration_ms)
      assert metadata.bucket == :overnight
    end
  end
end
