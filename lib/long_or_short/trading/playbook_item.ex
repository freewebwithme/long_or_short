defmodule LongOrShort.Trading.PlaybookItem do
  @moduledoc """
  Embedded item inside a `LongOrShort.Trading.Playbook` (LON-181, TW-1
  of [[LON-180]]).

  Pure structured representation of a single todo line on the
  trader's rules or setup checklist. Lives inside the parent
  `Playbook.items` array column (jsonb-serialized via Ash embedded
  data layer).

  ## Why an embed (not has_many)

  Solo-user app; check-state lookups need item identity that's stable
  through reorders and text edits. UUID primary key gives that for
  free — no 3-tier hash/index fallback needed (which an earlier
  markdown-parser draft required). Trade-off: editing UX in `/trading/edit`
  becomes form-based (add/edit/delete controls) rather than a raw
  textarea. Acceptable because freeform live note-taking lives in
  `Trading.Note` (LON-182), and playbook edits happen on a separate
  page anyway.

  ## Stable identity across edits

  `id` is a server-generated UUID v7. Created once at item-add time,
  preserved through any text edit / position change. `PlaybookCheckState.checked_items`
  uses these ids as keys — moving an item from position 0 to 2 keeps
  its check state. Editing the text keeps it. Deleting the item
  drops the check state on next save (the orphan key naturally
  ages out next time `:toggle_item` rewrites the map).

  ## Order

  Determined by position in the parent's `:items` list (Elixir list
  is ordered). No explicit `:order` attribute — adding one would
  duplicate state and create "list order says X, :order field says Y"
  bugs.
  """

  use Ash.Resource,
    otp_app: :long_or_short,
    data_layer: :embedded

  attributes do
    uuid_v7_primary_key :id

    attribute :text, :string do
      allow_nil? false
      public? true

      constraints min_length: 1, max_length: 280

      description """
      The item's display text. Soft-capped at 280 chars — long enough
      for "If price closes below VWAP after first 30 minutes, stop
      considering long entries" but short enough that the UI doesn't
      have to wrap dramatically.
      """
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      # `:id` is accepted so callers (e.g. the LON-184 edit UI) can
      # round-trip an existing item's UUID through a hidden form field.
      # Without this, every save would generate a fresh UUID and
      # invalidate the `PlaybookCheckState.checked_items` keys for
      # today's checks — the very thing the embed design was supposed
      # to preserve. If `:id` is omitted, the `uuid_v7_primary_key`
      # default fires server-side as usual.
      accept [:id, :text]
    end

    update :update do
      primary? true
      accept [:text]
    end
  end
end
