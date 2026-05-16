defmodule LongOrShort.Trading.FormatTest do
  @moduledoc """
  Tests for `LongOrShort.Trading.Format` (LON-181, TW-1 of [[LON-180]]).

  Verifies the prompt-injection markdown format consumed by TW-5
  ([[LON-185]]). Output shape matters because the Pre-Trade Briefing
  LLM's instructions reference section headers (`## Trader's Playbook`,
  `### Daily Rules`, `### Setups (active)`) by name.
  """

  use LongOrShort.DataCase, async: false

  import LongOrShort.AccountsFixtures
  import LongOrShort.TradingFixtures

  alias LongOrShort.Trading.Format

  describe "format_playbook_for_prompt/2 — empty cases" do
    test "returns empty string when user has no playbooks" do
      user = build_trader_user()
      assert Format.format_playbook_for_prompt(user.id) == ""
    end
  end

  describe "format_playbook_for_prompt/2 — populated" do
    test "renders rules + setups in the expected markdown shape" do
      user = build_trader_user()

      build_playbook(%{
        user_id: user.id,
        kind: :rules,
        name: "Daily rules",
        items: [
          %{text: "Daily max loss $160"},
          %{text: "2회 연속 손절 시 거래 종료"}
        ]
      })

      build_playbook(%{
        user_id: user.id,
        kind: :setup,
        name: "Long setup",
        items: [
          %{text: "Price $2-$10"},
          %{text: "Catalyst present"}
        ]
      })

      build_playbook(%{
        user_id: user.id,
        kind: :setup,
        name: "Short setup",
        items: [
          %{text: "ADX < 15 (choppy)"},
          %{text: "Quick stop, ATR-based"}
        ]
      })

      output = Format.format_playbook_for_prompt(user.id)

      expected = """
      ## Trader's Playbook

      ### Daily Rules

      - Daily max loss $160
      - 2회 연속 손절 시 거래 종료

      ### Setups (active)

      **Long setup**
      - Price $2-$10
      - Catalyst present

      **Short setup**
      - ADX < 15 (choppy)
      - Quick stop, ATR-based\
      """

      assert output == expected
    end

    test "rules-only — no Setups section" do
      user = build_trader_user()

      build_playbook(%{
        user_id: user.id,
        kind: :rules,
        name: "Daily rules",
        items: [%{text: "Stop loss 엄수"}]
      })

      output = Format.format_playbook_for_prompt(user.id)

      assert output =~ "### Daily Rules"
      refute output =~ "### Setups (active)"
    end

    test "setups-only — no Daily Rules section" do
      user = build_trader_user()

      build_playbook(%{
        user_id: user.id,
        kind: :setup,
        name: "Long setup",
        items: [%{text: "Price $2-$10"}]
      })

      output = Format.format_playbook_for_prompt(user.id)

      assert output =~ "### Setups (active)"
      assert output =~ "**Long setup**"
      refute output =~ "### Daily Rules"
    end

    test "multiple setups appear with bold name headers, separated by blank lines" do
      user = build_trader_user()

      build_playbook(%{
        user_id: user.id,
        kind: :setup,
        name: "Long setup",
        items: [%{text: "Long item 1"}]
      })

      build_playbook(%{
        user_id: user.id,
        kind: :setup,
        name: "Gap-up setup",
        items: [%{text: "Gap item 1"}]
      })

      output = Format.format_playbook_for_prompt(user.id)

      # Both setup names present with bold markdown
      assert output =~ "**Long setup**"
      assert output =~ "**Gap-up setup**"

      # Sort order: setups sorted alphabetically by name within the section.
      # "Gap-up setup" < "Long setup" lexicographically.
      gap_pos = :binary.match(output, "**Gap-up setup**") |> elem(0)
      long_pos = :binary.match(output, "**Long setup**") |> elem(0)
      assert gap_pos < long_pos
    end
  end

  describe "format_playbook_for_prompt/2 — cross-user isolation" do
    test "another user's playbooks do not leak into the output" do
      mine = build_trader_user()
      other = build_trader_user()

      build_playbook(%{
        user_id: mine.id,
        kind: :rules,
        name: "Daily rules",
        items: [%{text: "My rule"}]
      })

      build_playbook(%{
        user_id: other.id,
        kind: :rules,
        name: "Daily rules",
        items: [%{text: "Other's secret rule"}]
      })

      output = Format.format_playbook_for_prompt(mine.id)

      assert output =~ "My rule"
      refute output =~ "Other's secret rule"
    end
  end

  describe "format_playbook_for_prompt/2 — inactive versions excluded" do
    test "only the active version of each chain is rendered" do
      user = build_trader_user()

      # v1 (will be deactivated when v2 lands)
      build_playbook(%{
        user_id: user.id,
        kind: :rules,
        name: "Daily rules",
        items: [%{text: "v1 deprecated rule"}]
      })

      # v2 — active
      build_playbook(%{
        user_id: user.id,
        kind: :rules,
        name: "Daily rules",
        items: [%{text: "v2 current rule"}]
      })

      output = Format.format_playbook_for_prompt(user.id)

      assert output =~ "v2 current rule"
      refute output =~ "v1 deprecated rule"
    end
  end
end
