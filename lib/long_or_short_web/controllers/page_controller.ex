defmodule LongOrShortWeb.PageController do
  use LongOrShortWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
