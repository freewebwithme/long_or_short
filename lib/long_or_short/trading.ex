defmodule LongOrShort.Trading do
  @moduledoc """
  Trading Workspace domain — the trader's live work surface (LON-180
  epic, TW-1 foundation).

  Replaces the user's paper-based daily routine:

    * **Playbook** (`LongOrShort.Trading.Playbook`) — versioned rules
      and setup checklists (`kind: :rules | :setup`). Per-(user, kind,
      name) version chain capped at 3; over-cap save attempts return
      an error directing the user to manually delete an old version
      via `/trading/edit` (TW-4). Manual delete avoids surprise data
      loss vs. the original auto-delete-oldest design.

    * **PlaybookCheckState** (`LongOrShort.Trading.PlaybookCheckState`)
      — today's checked-item map per `(user, playbook, trading_date)`,
      where `trading_date` is ET-based. Toggling a markdown todo item
      mutates the `:checked_items` map. Retrospection consumers
      (`Research` POST-1, LON-176) read past dates to ask "did you
      check rule #3 before entering?".

    * **Note** (`LongOrShort.Trading.Note`, lands in TW-2 / LON-182) —
      daily journal entry, one row per `(user, trading_date)`.

  Future tenants:

    * **StockTrade** (LON-86 journaling) — trade execution records
      that join against `PlaybookCheckState` for rule-violation
      analysis.

  ## Domain registration

  Listed in `:ash_domains` in `config/config.exs` alongside Research,
  Filings, Analysis, etc. Each domain owns one or more resources and
  exposes a code-interface surface for callers (LiveViews, workers).

  ## Why a separate domain (not under Research / Accounts)

  `Research` is for AI-driven on-demand investigations. `Accounts` is
  identity + auth. Trading Workspace is the trader's own working
  artifacts — rules they wrote, notes they took, items they checked.
  Distinct lifecycle, distinct policy story (everything is per-user
  owned), distinct future growth (journaling, post-trade review).
  Putting it under an existing domain would conflate concerns.
  """

  use Ash.Domain, otp_app: :long_or_short

  resources do
    resource LongOrShort.Trading.Playbook do
      # Primary write path — creates the next version in the
      # (user, kind, name) chain. Subject to the 3-version cap;
      # over-cap returns `{:error, …}` rather than auto-deleting.
      # `items` is a list of `%{text: "..."}` maps (UUIDs auto-
      # generated server-side via the embed default).
      define :create_playbook_version,
        action: :create_version,
        args: [:user_id, :kind, :name, :items]

      # Typo-fix path — mutates the active row's items in place
      # without bumping version. Caller is responsible for keeping
      # existing item ids in the new list (TW-4 form UI round-trips
      # them in hidden inputs).
      define :update_playbook_items, action: :update_items, args: [:items]

      # Active playbook list (all `active: true` rows for a user,
      # which is the latest version of each (kind, name) chain).
      # Consumed by the /trading LiveView (TW-3) and the Pre-Trade
      # Briefing formatter (TW-5).
      define :list_active_playbooks, action: :read_active, args: [:user_id]

      # Full version history for a single (user, kind, name). Used by
      # the /trading/edit history view (TW-4).
      define :list_playbook_versions,
        action: :read_all_versions,
        args: [:user_id, :kind, :name]

      # Get a single playbook by id — used by check-state actions
      # and the edit UI.
      define :get_playbook, action: :read, get_by: [:id], not_found_error?: false

      define :destroy_playbook, action: :destroy
    end

    resource LongOrShort.Trading.PlaybookCheckState do
      # Upsert today's state for a single playbook. Creates the
      # `(user, playbook, trading_date)` row if missing; returns the
      # existing one otherwise.
      define :upsert_check_state_for_today,
        action: :upsert_for_today,
        args: [:user_id, :playbook_id]

      # Toggle a single markdown todo item. Adds the item_id with the
      # current timestamp if absent; removes it if present.
      define :toggle_playbook_item,
        action: :toggle_item,
        args: [:item_id]

      # All check states for a specific date (one row per playbook).
      # Used by retrospection (LON-176).
      define :list_check_states_for_date,
        action: :read_for_date,
        args: [:user_id, :trading_date]

      # Today's check states across all the user's playbooks. The
      # /trading LiveView (TW-3) loads this on mount.
      define :list_check_states_for_today,
        action: :read_today,
        args: [:user_id]
    end
  end
end
