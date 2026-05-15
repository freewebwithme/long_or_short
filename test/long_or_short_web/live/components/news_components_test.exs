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
      analysis = build_analysis(%{})

      profile = %{
        overall_severity: :high,
        overall_severity_reason: "Recent ATM",
        flags: [],
        data_completeness: :partial
      }

      html =
        render_component(&NewsComponents.news_card/1, %{
          analysis: analysis,
          expanded?: false,
          dilution_profile: profile
        })

      # The dilution pill from the live profile
      assert html =~ "Dilution"
      assert html =~ "HIGH"

      # Existing pills still rendered (regression guard for the
      # `news_card` row addition not breaking anything else).
      assert html =~ "Strength"
      assert html =~ "Strategy"
    end

    test "renders unknown badge when profile is nil (LON-162)" do
      analysis = build_analysis(%{})

      html =
        render_component(&NewsComponents.news_card/1, %{
          analysis: analysis,
          expanded?: false,
          dilution_profile: nil
        })

      assert html =~ "UNKNOWN"
      assert html =~ "border-dashed"
    end

    test "renders unknown badge when profile is :insufficient (LON-162)" do
      analysis = build_analysis(%{})

      profile = %{
        overall_severity: :none,
        overall_severity_reason: nil,
        flags: [],
        data_completeness: :insufficient
      }

      html =
        render_component(&NewsComponents.news_card/1, %{
          analysis: analysis,
          expanded?: false,
          dilution_profile: profile
        })

      assert html =~ "UNKNOWN"
      assert html =~ "border-dashed"
    end
  end

  describe "news_detail dilution_section" do
    test "renders summary text and flag chips when severity is high" do
      analysis = build_analysis(%{})

      profile = %{
        overall_severity: :high,
        overall_severity_reason: "HIGH dilution event with substantial overhang",
        flags: [:large_overhang, :death_spiral_convertible],
        data_completeness: :partial
      }

      html =
        render_component(&NewsComponents.news_detail/1, %{
          analysis: analysis,
          dilution_profile: profile
        })

      assert html =~ "Dilution context"
      assert html =~ "substantial overhang"
      assert html =~ "large overhang"
      assert html =~ "death spiral convertible"
    end

    test "renders summary even when flags list is empty" do
      analysis = build_analysis(%{})

      profile = %{
        overall_severity: :medium,
        overall_severity_reason: "Warrant overhang reaching strike",
        flags: [],
        data_completeness: :partial
      }

      html =
        render_component(&NewsComponents.news_detail/1, %{
          analysis: analysis,
          dilution_profile: profile
        })

      assert html =~ "Dilution context"
      assert html =~ "Warrant overhang"
    end

    test "hides dilution section when profile is :insufficient AND flags empty (LON-162)" do
      analysis = build_analysis(%{})

      profile = %{
        overall_severity: :none,
        overall_severity_reason: nil,
        flags: [],
        data_completeness: :insufficient
      }

      html =
        render_component(&NewsComponents.news_detail/1, %{
          analysis: analysis,
          dilution_profile: profile
        })

      # LON-162: the dashed-border pill still surfaces "no data" via the
      # compact card. The expanded detail section adds nothing when both
      # severity and flags are empty, so we collapse it (same rule as
      # the pre-LON-162 :none + [] case).
      refute html =~ "Dilution context"
    end

    test "hides dilution section when profile is nil (LON-162)" do
      analysis = build_analysis(%{})

      html =
        render_component(&NewsComponents.news_detail/1, %{
          analysis: analysis,
          dilution_profile: nil
        })

      refute html =~ "Dilution context"
    end

    test "hides dilution section when severity none AND flags empty" do
      analysis = build_analysis(%{})

      profile = %{
        overall_severity: :none,
        overall_severity_reason: nil,
        flags: [],
        data_completeness: :high
      }

      html =
        render_component(&NewsComponents.news_detail/1, %{
          analysis: analysis,
          dilution_profile: profile
        })

      refute html =~ "Dilution context"
    end

    test "shows section when severity none but flags present" do
      # Edge case: rules engine surfaces a flag even when overall
      # severity is none (e.g. structural pattern signal but no
      # active dilution). Render the section so the trader sees the
      # flag chip.
      analysis = build_analysis(%{})

      profile = %{
        overall_severity: :none,
        overall_severity_reason: nil,
        flags: [:large_overhang],
        data_completeness: :high
      }

      html =
        render_component(&NewsComponents.news_detail/1, %{
          analysis: analysis,
          dilution_profile: profile
        })

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
