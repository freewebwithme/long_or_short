defmodule LongOrShortWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use LongOrShortWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_user, :map,
    default: nil,
    doc: "the currently authenticated user, if any"

  attr :current_path, :string, default: nil

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="navbar border-b border-base-300 px-4 sm:px-6 lg:px-8 sticky top-0 bg-base-100 z-30">
      <div class="flex-1">
        <a href="/" class="flex items-center font-bold text-lg gap-1">
          <span class="text-success inline-flex items-center gap-1">
            <.icon name="hero-arrow-trending-up" class="size-4" /> Long
          </span>
          <span class="opacity-60">or</span>
          <span class="text-error inline-flex items-center gap-1">
            <.icon name="hero-arrow-trending-down" class="size-4" /> Short
          </span>
        </a>
      </div>

      <nav class="flex-none flex items-center gap-2">
        <ul class="flex items-center gap-1 mr-2">
          <li>
            <.link
              navigate={~p"/"}
              class={[
                "btn btn-ghost btn-sm",
                @current_path == "/" && "btn-active"
              ]}
            >
              Dashboard
            </.link>
          </li>
          <li>
            <.link
              navigate={~p"/feed"}
              class={[
                "btn btn-ghost btn-sm",
                @current_path == "/feed" && "btn-active"
              ]}
            >
              Feed
            </.link>
          </li>
          <li>
            <.link
              navigate={~p"/morning"}
              class={[
                "btn btn-ghost btn-sm",
                @current_path == "/morning" && "btn-active"
              ]}
            >
              Morning
            </.link>
          </li>
          <li>
            <.link
              navigate={~p"/scout"}
              class={[
                "btn btn-ghost btn-sm",
                String.starts_with?(@current_path || "", "/scout") && "btn-active"
              ]}
            >
              Scout
            </.link>
          </li>
          <li>
            <.link
              navigate={~p"/analyze"}
              class={[
                "btn btn-ghost btn-sm",
                String.starts_with?(@current_path || "", "/analyze") && "btn-active"
              ]}
            >
              Analyze
            </.link>
          </li>
          <li>
            <.link
              navigate={~p"/watchlist"}
              class={[
                "btn btn-ghost btn-sm",
                @current_path == "/watchlist" && "btn-active"
              ]}
            >
              Watchlist
            </.link>
          </li>
        </ul>

        <div :if={@current_user} class="dropdown dropdown-end">
          <div tabindex="0" role="button" class="btn btn-ghost btn-sm btn-circle">
            <.icon name="hero-user-circle" class="size-5" />
          </div>
          <ul
            tabindex="0"
            class="menu menu-sm dropdown-content bg-base-200 rounded-box z-40 mt-2 w-64 p-2 shadow"
          >
            <li class="menu-title">
              <div class="text-xs opacity-60 truncate" title={@current_user.email}>
                {@current_user.email}
              </div>
            </li>
            <li><.link navigate={~p"/profile"}>Profile</.link></li>
            <li><.link navigate={~p"/playbook"}>Playbook</.link></li>
            <li><.link navigate={~p"/settings"}>Settings</.link></li>
            <li>
              <.link href={~p"/sign-out"} method="delete">Sign out</.link>
            </li>
          </ul>
        </div>

        <.link :if={!@current_user} href={~p"/sign-in"} class="btn btn-primary btn-sm">
          Sign in
        </.link>
      </nav>
    </header>

    <main class="px-4 py-6 sm:px-6 lg:px-8">
      <div class="mx-auto max-w-6xl">
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
