defmodule LongOrShortWeb.SettingsLive do
  @moduledoc """
  /settings — app-wide preferences page.

  Phase 1 hosts a single live control (theme toggle, moved here from the top
  nav) plus structural placeholders for sections that future tickets will
  fill in. Keeping the empty cards visible documents what's coming and lets
  the visual frame stabilize before each feature lands.
  """
  use LongOrShortWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_path={@current_path}>
      <div class="max-w-2xl space-y-4">
        <h1 class="text-2xl font-bold mb-4">Settings</h1>

        <section id="settings-appearance" class="card bg-base-200 border border-base-300 p-4">
          <h2 class="font-semibold mb-3">Appearance</h2>
          <div class="flex items-center gap-4">
            <Layouts.theme_toggle />
            <p class="text-xs opacity-60">Choose system, light, or dark mode.</p>
          </div>
        </section>

        <section
          id="settings-notifications"
          class="card bg-base-200 border border-base-300 p-4 opacity-60"
        >
          <h2 class="font-semibold mb-1">Notifications</h2>
          <p class="text-xs italic">Coming soon — alerting on watchlist news and price moves.</p>
        </section>

        <section
          id="settings-data-sources"
          class="card bg-base-200 border border-base-300 p-4 opacity-60"
        >
          <h2 class="font-semibold mb-1">Data sources</h2>
          <p class="text-xs italic">Coming soon — manage external API keys and feed preferences.</p>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
