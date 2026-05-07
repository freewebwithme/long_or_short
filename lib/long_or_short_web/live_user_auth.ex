defmodule LongOrShortWeb.LiveUserAuth do
  @moduledoc """
  Helpers for authenticating users in LiveViews.
  """

  import Phoenix.Component
  use LongOrShortWeb, :verified_routes

  # This is used for nested liveviews to fetch the current user.
  # To use, place the following at the top of that liveview:
  # on_mount {LongOrShortWeb.LiveUserAuth, :current_user}
  def on_mount(:current_user, _params, session, socket) do
    {:cont, AshAuthentication.Phoenix.LiveSession.assign_new_resources(socket, session)}
  end

  def on_mount(:live_user_optional, _params, _session, socket) do
    if socket.assigns[:current_user] do
      {:cont, socket}
    else
      {:cont, assign(socket, :current_user, nil)}
    end
  end

  def on_mount(:live_user_required, _params, _session, socket) do
    if socket.assigns[:current_user] do
      {:cont, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/sign-in")}
    end
  end

  def on_mount(:live_no_user, _params, _session, socket) do
    if socket.assigns[:current_user] do
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/")}
    else
      {:cont, assign(socket, :current_user, nil)}
    end
  end

  def on_mount(:assign_current_path, _params, _session, socket) do
    socket =
      socket
      |> Phoenix.Component.assign(:current_path, "/")
      |> Phoenix.LiveView.attach_hook(
        :assign_current_path,
        :handle_params,
        &assign_current_path_hook/3
      )

    {:cont, socket}
  end

  # Loads `:trading_profile` onto `current_user` so authenticated LiveViews
  # can decide whether to gate the Analyze flow without each one repeating
  # the preload in its own `mount/3`. LON-102.
  def on_mount(:preload_trading_profile, _params, _session, socket) do
    case socket.assigns[:current_user] do
      %{} = user ->
        loaded = Ash.load!(user, :trading_profile, authorize?: false)
        {:cont, assign(socket, :current_user, loaded)}

      _ ->
        {:cont, socket}
    end
  end

  defp assign_current_path_hook(_params, uri, socket) do
    path = URI.parse(uri).path || "/"
    {:cont, Phoenix.Component.assign(socket, :current_path, path)}
  end
end
