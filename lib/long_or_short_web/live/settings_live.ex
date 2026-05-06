defmodule LongOrShortWeb.SettingsLive do
  @moduledoc """
  Placeholder for the app settings page (/settings).

  Sub-4 (LON-99) will replace this body with the real settings panel —
  theme toggle plus future-prefs sections. This stub exists so the
  dropdown link from Sub-1 (LON-96) resolves and the route is reserved.
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
      <section id="settings-placeholder" class="card bg-base-200 border border-base-300 p-4">
        <h2 class="font-semibold mb-3">Settings</h2>
        <p class="text-sm opacity-60">Coming soon — LON-99 will build this page.</p>
      </section>
    </Layouts.app>
    """
  end
end
