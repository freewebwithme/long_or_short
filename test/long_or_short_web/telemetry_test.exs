defmodule LongOrShortWeb.TelemetryTest do
  @moduledoc """
  Regression guard for the metric registry (LON-168).

  We don't test framework plumbing here — `Telemetry.Metrics` is
  already covered upstream. What we DO guard against is the easy
  failure mode of someone adding a new `:telemetry.execute/3` site
  in domain code and forgetting to register it in
  `LongOrShortWeb.Telemetry.metrics/0`, leaving the event invisible.

  Each registered event is asserted by event-name presence. The
  exact metric type (counter / summary / sum / last_value) is a
  per-event judgment call — we don't lock it in, just the fact that
  *something* registers.
  """

  use ExUnit.Case, async: true

  alias LongOrShortWeb.Telemetry

  defp registered_events do
    Telemetry.metrics()
    |> Enum.map(& &1.event_name)
    |> Enum.uniq()
  end

  describe "metrics/0" do
    test "returns a list of Telemetry.Metrics structs" do
      metrics = Telemetry.metrics()

      assert is_list(metrics)
      assert length(metrics) > 0

      for m <- metrics do
        # All registered metrics descend from the abstract
        # `Telemetry.Metrics` struct family.
        assert is_struct(m),
               "expected a Telemetry.Metrics struct, got: #{inspect(m)}"

        assert is_list(m.event_name),
               "expected event_name to be a list, got: #{inspect(m.event_name)}"
      end
    end

    test "covers every custom domain event currently emitted in lib/" do
      events = registered_events()

      expected_events = [
        # AI providers
        [:long_or_short, :ai, :claude, :call],
        [:long_or_short, :ai, :claude, :call_with_search],
        [:long_or_short, :ai, :qwen, :call],

        # Tier 1 + Tier 2 + body + form 4 + backfill (LON-135 + BatchHelper)
        [:long_or_short, :filing_analysis_worker, :complete],
        [:long_or_short, :filing_severity_worker, :complete],
        [:long_or_short, :filing_body_fetcher, :complete],
        [:long_or_short, :form4_worker, :complete],
        [:long_or_short, :filing_analysis_backfill, :complete],

        # Ingest health (LON-161)
        [:long_or_short, :filings, :cik_drop],
        [:long_or_short, :ingest_health, :daily_summary],

        # Profile + universe sync (LON-167 + LON-133)
        [:long_or_short, :finnhub_profile_sync, :complete],
        [:long_or_short, :small_cap_universe, :sync_complete],

        # FinnhubStream lifecycle (LON-67)
        [:long_or_short, :finnhub_stream, :disconnected],
        [:long_or_short, :finnhub_stream, :reconnected],

        # Morning Brief (LON-148 family)
        [:long_or_short, :morning_brief, :generated],
        [:long_or_short, :morning_brief, :generation_failed]
      ]

      missing = expected_events -- events

      assert missing == [],
             """
             metrics/0 is missing #{length(missing)} domain event(s):
             #{inspect(missing, pretty: true)}

             If a new emit site was added, register it in
             `LongOrShortWeb.Telemetry.metrics/0` or add an
             explanatory comment in the "Skipped emits" section.
             """
    end

    test "Phoenix/Repo/VM defaults are still present" do
      events = registered_events()

      assert [:phoenix, :endpoint, :stop] in events
      assert [:long_or_short, :repo, :query] in events
      assert [:vm, :memory] in events
    end
  end

  describe "console_metrics/0 (LON-169)" do
    test "excludes :repo events to avoid flooding the dev console" do
      events =
        LongOrShortWeb.Telemetry.console_metrics()
        |> Enum.map(& &1.event_name)
        |> Enum.uniq()

      refute [:long_or_short, :repo, :query] in events
    end

    test "excludes non-:long_or_short events (Phoenix, VM)" do
      console_prefixes =
        LongOrShortWeb.Telemetry.console_metrics()
        |> Enum.map(fn m -> hd(m.event_name) end)
        |> Enum.uniq()

      assert console_prefixes == [:long_or_short],
             "console_metrics/0 leaked a non-:long_or_short event: #{inspect(console_prefixes)}"
    end

    test "includes the worker complete events that motivated LON-168" do
      events =
        LongOrShortWeb.Telemetry.console_metrics()
        |> Enum.map(& &1.event_name)
        |> Enum.uniq()

      assert [:long_or_short, :filing_analysis_worker, :complete] in events
      assert [:long_or_short, :ingest_health, :daily_summary] in events
      assert [:long_or_short, :finnhub_stream, :disconnected] in events
    end
  end
end
