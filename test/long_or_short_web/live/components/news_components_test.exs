defmodule LongOrShortWeb.Live.Components.NewsComponentsTest do
  @moduledoc """
  Unit tests for `LongOrShortWeb.Live.Components.NewsComponents` -
  LON-123 (dilution snapshot display) on top of LON-83 / LON-117.

  Uses `Phoenix.LiveViewTest.render_component/2` to render individual
  function components - no full LiveView mount needed. Builds
  `%NewsAnalysis{}` structs in-memory; no DB.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias LongOrShort.Analysis.NewsAnalysis
  alias LongOrShortWeb.Live.Components.NewsComponents

  describe "dilution_pill - severity color mapping" do
    test "critical renders as red plus bold" do
      html =
        render_component(&NewsComponents.dilution_pill/1, %{
          severity: :critical,
          summary: "ATM over half float"
        })

      assert html =~ "Dilution"
      assert html =~ "CRITICAL"
      assert html =~ "bg-error/20"
      assert html =~ "text-error"
      assert html =~ "font-bold"
      refute html =~ "border-dashed"
    end

    test "high renders as red, not bold" do
      html =
        render_component(&NewsComponents.dilution_pill/1, %{
          severity: :high,
          summary: "Recent S-1"
        })

      assert html =~ "HIGH"
      assert html =~ "bg-error/20"
      assert html =~ "text-error"
      refute html =~ "font-bold"
      refute html =~ "border-dashed"
    end

    test "medium renders as warning amber" do
      html =
        render_component(&NewsComponents.dilution_pill/1, %{severity: :medium, summary: nil})

      assert html =~ "MEDIUM"
      assert html =~ "bg-warning/20"
      assert html =~ "text-warning"
      refute html =~ "border-dashed"
    end

    test "low renders as subtle but visible" do
      html = render_component(&NewsComponents.dilution_pill/1, %{severity: :low, summary: nil})

      assert html =~ "LOW"
      assert html =~ "bg-base-300"
      assert html =~ "opacity-80"
      refute html =~ "border-dashed"
    end

    test "none renders as subtle gray, NOT dashed" do
      html = render_component(&NewsComponents.dilution_pill/1, %{severity: :none, summary: nil})

      assert html =~ "NONE"
      assert html =~ "bg-base-300"
      assert html =~ "opacity-60"
      refute html =~ "border-dashed"
    end

    test "unknown renders dashed - visually distinct from none" do
      # Default-safe rule (LON-117): "no data" must NOT look the same
      # as "data, no risk." Dashed border is the visual handle for
      # that distinction, matching the Phase 1 stub pills.
      html =
        render_component(&NewsComponents.dilution_pill/1, %{
          severity: :unknown,
          summary: "Unknown no dilution data in last 180 days"
        })

      assert html =~ "UNKNOWN"
      assert html =~ "border-dashed"
    end
  end

  describe "dilution_pill - tooltip" do
    test "summary renders as the title attribute (hover tooltip)" do
      html =
        render_component(&NewsComponents.dilution_pill/1, %{
          severity: :high,
          summary: "Recent ATM with discount pricing"
        })

      assert html =~ ~s(title="Recent ATM with discount pricing")
    end

    test "nil summary still renders the pill" do
      html = render_component(&NewsComponents.dilution_pill/1, %{severity: :none, summary: nil})

      assert html =~ "Dilution"
      assert html =~ "NONE"
    end
  end

  describe "news_card includes dilution pill" do
    test "renders the dilution pill alongside the other signals" do
      analysis =
        build_analysis(%{
          dilution_severity_at_analysis: :high,
          dilution_summary_at_analysis: "Recent ATM"
        })

      html =
        render_component(&NewsComponents.news_card/1, %{analysis: analysis, expanded?: false})

      # The new pill
      assert html =~ "Dilution"
      assert html =~ "HIGH"

      # Existing pills still rendered (regression guard for the
      # `news_card` row addition not breaking anything else).
      assert html =~ "Strength"
      assert html =~ "Strategy"
    end

    test "renders unknown badge when analysis has no dilution data" do
      analysis =
        build_analysis(%{
          dilution_severity_at_analysis: :unknown,
          dilution_summary_at_analysis: "Unknown no dilution data"
        })

      html =
        render_component(&NewsComponents.news_card/1, %{analysis: analysis, expanded?: false})

      assert html =~ "UNKNOWN"
      assert html =~ "border-dashed"
    end
  end

  describe "news_detail dilution_section" do
    test "renders summary text and flag chips when severity is high" do
      analysis =
        build_analysis(%{
          dilution_severity_at_analysis: :high,
          dilution_summary_at_analysis: "HIGH dilution event with substantial overhang",
          dilution_flags_at_analysis: [:large_overhang, :death_spiral_convertible]
        })

      html = render_component(&NewsComponents.news_detail/1, %{analysis: analysis})

      assert html =~ "Dilution context"
      assert html =~ "substantial overhang"
      assert html =~ "large overhang"
      assert html =~ "death spiral convertible"
    end

    test "renders summary even when flags list is empty" do
      analysis =
        build_analysis(%{
          dilution_severity_at_analysis: :medium,
          dilution_summary_at_analysis: "Warrant overhang reaching strike",
          dilution_flags_at_analysis: []
        })

      html = render_component(&NewsComponents.news_detail/1, %{analysis: analysis})

      assert html =~ "Dilution context"
      assert html =~ "Warrant overhang"
    end

    test "renders unknown warning explicitly (no-data signal)" do
      analysis =
        build_analysis(%{
          dilution_severity_at_analysis: :unknown,
          dilution_summary_at_analysis: "Unknown no dilution data in last 180 days",
          dilution_flags_at_analysis: []
        })

      html = render_component(&NewsComponents.news_detail/1, %{analysis: analysis})

      assert html =~ "Dilution context"
      assert html =~ "Unknown"
      assert html =~ "no dilution data"
    end

    test "hides dilution section when severity none AND flags empty" do
      analysis =
        build_analysis(%{
          dilution_severity_at_analysis: :none,
          dilution_summary_at_analysis: nil,
          dilution_flags_at_analysis: []
        })

      html = render_component(&NewsComponents.news_detail/1, %{analysis: analysis})

      refute html =~ "Dilution context"
    end

    test "shows section when severity none but flags present" do
      # Edge case: rules engine surfaces a flag even when overall
      # severity is none (e.g. structural pattern signal but no
      # active dilution). Render the section so the trader sees the
      # flag chip.
      analysis =
        build_analysis(%{
          dilution_severity_at_analysis: :none,
          dilution_summary_at_analysis: nil,
          dilution_flags_at_analysis: [:large_overhang]
        })

      html = render_component(&NewsComponents.news_detail/1, %{analysis: analysis})

      assert html =~ "Dilution context"
      assert html =~ "large overhang"
    end
  end

  # Helper builds a complete NewsAnalysis struct in-memory for
  # component rendering. Component tests don't need DB or policy -
  # just struct shape with all required fields populated. Real rows
  # come via the analyzer; this mirrors the row shape it produces.
  defp build_analysis(overrides) do
    base = %NewsAnalysis{
      article_id: "00000000-0000-0000-0000-000000000001",
      catalyst_strength: :strong,
      catalyst_type: :partnership,
      sentiment: :positive,
      pump_fade_risk: :insufficient_data,
      repetition_count: 1,
      strategy_match: :partial,
      verdict: :trade,
      headline_takeaway: "Test takeaway",
      dilution_severity_at_analysis: :unknown,
      dilution_flags_at_analysis: [],
      dilution_summary_at_analysis: nil,
      detail_summary: nil,
      detail_positives: nil,
      detail_concerns: nil,
      detail_checklist: nil,
      detail_recommendation: nil
    }

    struct(base, overrides)
  end
end
