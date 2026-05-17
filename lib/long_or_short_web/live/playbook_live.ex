defmodule LongOrShortWeb.PlaybookLive do
  @moduledoc """
  Read-only view of the trader's active `Trading.Playbook` set
  (LON-184, TW-4 of [[LON-180]]).

  Lives at `/playbook` and surfaces from the gear-menu dropdown (next
  to Profile / Settings). Edit access is gated behind an explicit
  click → `/playbook/edit` (`PlaybookEditLive`). The split exists to
  match how the trader thinks about Playbook: "look first, edit only
  when I actually want to change something." Mirrors the "view
  before edit" pattern from Scout (`/scout/b/:id` detail vs `/scout`
  run flow).

  ## What's rendered

    * Grouped by `kind` (Rules first, then Setups)
    * Each playbook shows: name, version chip, items as a static
      bullet list, item count
    * Empty state when the user has no active playbooks — primary
      CTA → `/playbook/edit`

  ## What's NOT here

    * No editing (forms, item add/remove) — that's `PlaybookEditLive`
    * No version history view — also in the edit page
    * No real-time subscription — single-author resource, refresh
      on next visit is fine
  """

  use LongOrShortWeb, :live_view

  alias LongOrShort.Trading

  @impl true
  def mount(_params, _session, socket) do
    {:ok, load_playbooks(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app current_path={@current_path} current_user={@current_user} flash={@flash}>
      <div class="max-w-3xl mx-auto space-y-4">
        <div class="flex items-center justify-between">
          <h1 class="text-2xl font-bold">Playbook</h1>
          <.link navigate={~p"/playbook/edit"} class="btn btn-primary btn-sm">
            <.icon name="hero-pencil-square" class="size-4" /> Edit
          </.link>
        </div>

        <p class="text-sm opacity-70">
          Your trading rules and setup checklists. The Pre-Trade Briefing
          reads these as context — your Scout reports prioritize risks
          that match these rules.
        </p>

        <%= if @playbooks == [] do %>
          <.empty_state />
        <% else %>
          <.section title="Daily Rules" playbooks={Enum.filter(@playbooks, &(&1.kind == :rules))} />
          <.section title="Setups" playbooks={Enum.filter(@playbooks, &(&1.kind == :setup))} />
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  # ── Render helpers ──────────────────────────────────────────────

  attr :title, :string, required: true
  attr :playbooks, :list, required: true

  defp section(assigns) do
    ~H"""
    <section :if={@playbooks != []} class="space-y-3">
      <h2 class="text-lg font-semibold opacity-80">{@title}</h2>
      <.playbook_card :for={pb <- @playbooks} playbook={pb} />
    </section>
    """
  end

  attr :playbook, :any, required: true

  defp playbook_card(assigns) do
    ~H"""
    <section
      id={"playbook-#{@playbook.id}"}
      class="card bg-base-200 border border-base-300 p-4"
    >
      <div class="flex items-baseline justify-between mb-3">
        <h3 class="font-semibold">{@playbook.name}</h3>
        <span class="text-xs opacity-60">
          v{@playbook.version} · {length(@playbook.items)} {item_label(@playbook.items)}
        </span>
      </div>

      <ul :if={@playbook.items != []} class="space-y-1 text-sm">
        <li :for={item <- @playbook.items} class="flex items-start gap-2">
          <span class="opacity-50">•</span>
          <span>{item.text}</span>
        </li>
      </ul>

      <p :if={@playbook.items == []} class="text-xs opacity-60 italic">
        No items yet — Edit to add some.
      </p>
    </section>
    """
  end

  defp empty_state(assigns) do
    ~H"""
    <section class="card bg-base-200 border border-base-300 p-8 text-center">
      <.icon name="hero-clipboard-document-list" class="size-10 mx-auto opacity-50" />
      <h2 class="font-semibold mt-3 mb-2">No playbooks yet</h2>
      <p class="text-sm opacity-70 mb-4">
        Create your first playbook to give the Pre-Trade Briefing your trading
        rules. A "Daily rules" playbook is the canonical starting point.
      </p>
      <.link navigate={~p"/playbook/edit"} class="btn btn-primary btn-sm mx-auto">
        Create your first playbook
      </.link>
    </section>
    """
  end

  # ── Internals ───────────────────────────────────────────────────

  defp load_playbooks(socket) do
    actor = socket.assigns.current_user

    playbooks =
      case Trading.list_active_playbooks(actor.id, actor: actor) do
        {:ok, list} -> list
        _ -> []
      end

    socket
    |> assign(:playbooks, playbooks)
    |> assign(:page_title, "Playbook")
  end

  defp item_label([_]), do: "item"
  defp item_label(_), do: "items"
end
