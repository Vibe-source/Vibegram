defmodule VibeWeb do
  @moduledoc """
  The entrypoint for defining your web interface, such
  as controllers, components, channels, and so on.
  """

  def static_paths, do: ~w(assets fonts images favicon.ico robots.txt logo.png sw.js manifest.json registerSW.js)

  def controller do
    quote do
      use Phoenix.Controller,
        formats: [:json]

      import Plug.Conn
      import VibeWeb.Gettext

      unquote(verified_routes())
    end
  end

  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  def html do
    quote do
      use Phoenix.Component

      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      import Phoenix.HTML
      import VibeWeb.CoreComponents
      import VibeWeb.Gettext

      alias Phoenix.LiveView.JS

      unquote(verified_routes())
    end
  end

  defp verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: VibeWeb.Endpoint,
        router: VibeWeb.Router,
        statics: VibeWeb.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
