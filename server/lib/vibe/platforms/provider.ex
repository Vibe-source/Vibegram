defmodule Vibe.Platforms.Provider do
  @moduledoc """
  Behaviour for multi-platform OAuth connectors (GitHub, Excel/Graph, Slack, …).
  """

  @type capability :: %{
          required(:id) => String.t(),
          required(:name) => String.t(),
          required(:description) => String.t(),
          optional(:risk) => String.t(),
          optional(:params) => map()
        }

  @callback id() :: String.t()
  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback icon() :: String.t()
  @callback category() :: String.t()
  @callback oauth_configured?() :: boolean()
  @callback default_scopes() :: [String.t()]
  @callback capabilities() :: [capability()]
  @callback authorize_url(state :: String.t(), scopes :: [String.t()]) ::
              {:ok, String.t()} | {:error, term()}
  @callback exchange_code(code :: String.t()) ::
              {:ok, map()} | {:error, term()}
  @callback refresh_tokens(refresh_token :: String.t()) ::
              {:ok, map()} | {:error, term()}
  @callback fetch_identity(access_token :: String.t()) ::
              {:ok, map()} | {:error, term()}
  @callback invoke_action(access_token :: String.t(), action :: String.t(), params :: map()) ::
              {:ok, map()} | {:error, term()}

  @optional_callbacks refresh_tokens: 1
end
