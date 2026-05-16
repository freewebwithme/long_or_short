defmodule LongOrShort.TradingFixtures do
  @moduledoc """
  Factory helpers for the `LongOrShort.Trading` domain (LON-181, TW-1
  of [[LON-180]]).

  Mirrors the `build_*` (no `_fixture` suffix) convention from
  `AccountsFixtures` / `TickersFixtures`. Lazily creates the
  required user if `:user_id` is not supplied — keeps test setup
  one-liner short when ownership doesn't matter to the assertion.
  """

  import LongOrShort.AccountsFixtures, only: [build_trader_user: 0]

  alias LongOrShort.Trading

  @default_items [
    %{text: "Daily max loss $160"},
    %{text: "2회 연속 손절 시 거래 종료"},
    %{text: "Stop loss 엄수"}
  ]

  @doc """
  Builds a `LongOrShort.Trading.Playbook` via `:create_version`.

  ## Overrides

    * `:user_id` — owning user. Lazily creates a trader user if omitted.
    * `:kind` — `:rules` (default) or `:setup`.
    * `:name` — chain identity name. Defaults to `"Daily rules"` for
      `:rules`, `"Long setup"` for `:setup`.
    * `:items` — list of `%{text: "..."}` maps. Defaults to a 3-item
      sample list.

  Subject to the 3-version cap — tests that need >3 versions of the
  same `(user, kind, name)` should call directly without the helper.
  """
  def build_playbook(overrides \\ %{}) do
    user_id = Map.get_lazy(overrides, :user_id, fn -> build_trader_user().id end)
    kind = Map.get(overrides, :kind, :rules)
    name = Map.get(overrides, :name, default_name_for(kind))
    items = Map.get(overrides, :items, @default_items)

    case Trading.create_playbook_version(user_id, kind, name, items, authorize?: false) do
      {:ok, playbook} -> playbook
      {:error, error} -> raise "build_playbook failed: #{inspect(error)}"
    end
  end

  @doc """
  Builds an empty `PlaybookCheckState` for today via `:upsert_for_today`.

  ## Overrides

    * `:user_id` — owning user. Required (or supply `:playbook_id`).
    * `:playbook_id` — parent playbook. Lazily creates one if omitted
      (with a matching `:user_id`).

  The `:trading_date` column is server-computed from ET wall-clock —
  tests that need a specific historical date should use the resource's
  `:create` action directly, not this helper.
  """
  def build_check_state(overrides \\ %{}) do
    user_id = Map.get_lazy(overrides, :user_id, fn -> build_trader_user().id end)

    playbook_id =
      Map.get_lazy(overrides, :playbook_id, fn ->
        build_playbook(%{user_id: user_id}).id
      end)

    case Trading.upsert_check_state_for_today(user_id, playbook_id, authorize?: false) do
      {:ok, cs} -> cs
      {:error, error} -> raise "build_check_state failed: #{inspect(error)}"
    end
  end

  defp default_name_for(:rules), do: "Daily rules"
  defp default_name_for(:setup), do: "Long setup"
end
