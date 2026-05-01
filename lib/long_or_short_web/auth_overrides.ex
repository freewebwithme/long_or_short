defmodule LongOrShortWeb.AuthOverrides do
  use AshAuthentication.Phoenix.Overrides

  override AshAuthentication.Phoenix.Components.Banner do
    set :image_url, "/images/long-or-short-wordmark.svg"
    set :dark_image_url, "/images/long-or-short-wordmark.svg"
    set :href_url, "/"
    set :text, ""
    set :image_class, "h-10 mx-auto"
  end
end
