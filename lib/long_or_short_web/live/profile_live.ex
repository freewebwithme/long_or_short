defmodule LongOrShortWeb.ProfileLive do
  @moduledoc """
  Placeholder for the user profile page (/profile).

  Sub-3 (LON-98) will replace this body with the real profile editor —
  personal info (full name, phone, avatar), password change, and
  TradingProfile editing. This stub exists so the dropdown link from
  Sub-1 (LON-96) resolves and the route is reserved.
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
      <section id="profile-placeholder" class="card bg-base-200 border border-base-300 p-4">
        <h2 class="font-semibold mb-3">Profile</h2>
        <p class="text-sm opacity-60">Coming soon — LON-98 will build this page.</p>
      </section>
    </Layouts.app>
    """
  end
end
