defmodule LongOrShortWeb.PageController do
  use LongOrShortWeb, :controller

  def home(conn, _params) do
    if conn.assigns[:current_user] do
      redirect(conn, to: ~p"/feed")
    else
      render(conn, :home)
    end
  end
end
