defmodule LongOrShort.Trading.Format do
  @moduledoc """
  Cross-resource view formatters for the Trading domain (LON-181,
  TW-1 foundation; consumed by TW-5 prompt injection in LON-185).

  Kept separate from resource modules because formatting is a
  read-side concern that joins data across multiple resources
  (playbooks of different `:kind`, eventually check states and
  notes too) and doesn't belong in any single resource's action
  surface.

  Pure module — no DB writes, no PubSub. All reads go through Ash
  code interfaces (`Trading.list_active_playbooks/2`) with
  `authorize?: false` because the caller has already established
  the actor context.
  """

  alias LongOrShort.Trading
  alias LongOrShort.Trading.Playbook

  @doc """
  Renders the user's active playbook as a Markdown block ready to
  drop into an LLM prompt.

  Returns an empty string if the user has no active playbooks —
  callers can include the result unconditionally without a nil
  check, and the Pre-Trade Briefing prompt (TW-5) handles the
  empty-string case by skipping the "Trader's Playbook" section
  entirely.

  ## Output shape

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
      - Quick stop, ATR-based

  Rules are flattened into a single section (most users have one
  `kind: :rules` playbook named "Daily rules"). Setups are split
  by `name` because a trader running Long + Short + Gap-up setups
  benefits from per-setup grouping. Order within each section
  follows the resource's `read_active` sort (`[kind, name]`).
  """
  @spec format_playbook_for_prompt(user_id :: Ash.UUID.t(), keyword()) :: String.t()
  def format_playbook_for_prompt(user_id, _opts \\ []) when is_binary(user_id) do
    case Trading.list_active_playbooks(user_id, authorize?: false) do
      {:ok, []} ->
        ""

      {:ok, playbooks} ->
        render(playbooks)

      _ ->
        ""
    end
  end

  # ── Internals ───────────────────────────────────────────────────

  defp render(playbooks) do
    rules = Enum.filter(playbooks, &(&1.kind == :rules))
    setups = Enum.filter(playbooks, &(&1.kind == :setup))

    sections =
      [render_rules(rules), render_setups(setups)]
      |> Enum.reject(&(&1 == ""))

    case sections do
      [] -> ""
      _ -> "## Trader's Playbook\n\n" <> Enum.join(sections, "\n\n")
    end
  end

  defp render_rules([]), do: ""

  defp render_rules(rules) do
    body =
      rules
      |> Enum.flat_map(& &1.items)
      |> Enum.map(&"- #{&1.text}")
      |> Enum.join("\n")

    "### Daily Rules\n\n" <> body
  end

  defp render_setups([]), do: ""

  defp render_setups(setups) do
    body =
      setups
      |> Enum.map(&render_one_setup/1)
      |> Enum.join("\n\n")

    "### Setups (active)\n\n" <> body
  end

  defp render_one_setup(%Playbook{name: name, items: items}) do
    lines =
      items
      |> Enum.map(&"- #{&1.text}")
      |> Enum.join("\n")

    "**#{name}**\n" <> lines
  end
end
