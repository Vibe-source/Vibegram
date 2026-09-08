defmodule Vibe.Platforms do
  @moduledoc """
  User-scoped multi-platform OAuth connections, grants, and server-proxied tool calls.
  """

  import Ecto.Query
  require Logger

  alias Vibe.ConnectionAuditEvent
  alias Vibe.ConnectionGrant
  alias Vibe.PlatformConnection
  alias Vibe.Platforms.Catalog
  alias Vibe.Platforms.TokenVault
  alias Vibe.Repo

  @state_salt "vibe.platform.oauth.v1"
  @state_max_age_sec 600
  @bridge_agents ~w[claude codex grok agy vibe]

  # # Catalog

  def catalog, do: Catalog.list()

  def provider_info(provider_id), do: Catalog.get(provider_id)


  def list_connections(user_id) when is_binary(user_id) do
    Repo.all(
      from c in PlatformConnection,
        where: c.user_id == ^user_id and c.status != "revoked",
        order_by: [asc: c.provider, desc: c.inserted_at],
        preload: [:grants]
    )
  end

  def get_connection(user_id, connection_id)
      when is_binary(user_id) and is_binary(connection_id) do
    Repo.one(
      from c in PlatformConnection,
        where: c.id == ^connection_id and c.user_id == ^user_id,
        preload: [:grants]
    )
  end

  def connection_payload(%PlatformConnection{} = conn) do
    %{
      id: conn.id,
      provider: conn.provider,
      externalAccountId: conn.external_account_id,
      externalAccountLogin: conn.external_account_login,
      displayName: conn.display_name,
      scopes: conn.scopes || [],
      status: conn.status,
      metadata: public_metadata(conn.metadata || %{}),
      lastUsedAt: conn.last_used_at,
      lastError: conn.last_error,
      capabilities: Catalog.capability_ids(conn.provider),
      grants: Enum.map(conn.grants || [], &grant_payload/1),
      createdAt: conn.inserted_at,
      updatedAt: conn.updated_at
    }
  end

  def grant_payload(%ConnectionGrant{} = grant) do
    %{
      id: grant.id,
      connectionId: grant.connection_id,
      granteeType: grant.grantee_type,
      granteeId: grant.grantee_id,
      capabilities: grant.capabilities || [],
      enabled: grant.enabled,
      createdAt: grant.inserted_at
    }
  end


  def start_authorize(user_id, provider_id, opts \\ [])
      when is_binary(user_id) and is_binary(provider_id) do
    provider_id = normalize_provider(provider_id)

    with {:ok, mod} <- provider_module(provider_id),
         :ok <- require_oauth_configured(mod),
         scopes <- Keyword.get(opts, :scopes) || mod.default_scopes(),
         state <- sign_state(%{"uid" => user_id, "provider" => provider_id, "n" => nonce()}),
         {:ok, url} <- mod.authorize_url(state, scopes) do
      audit(nil, user_id, "user", user_id, "authorize_started", nil, %{
        "provider" => provider_id
      })

      {:ok, %{authorizeUrl: url, state: state, provider: provider_id, scopes: scopes}}
    end
  end

  def complete_oauth(provider_id, code, state)
      when is_binary(provider_id) and is_binary(code) and is_binary(state) do
    provider_id = normalize_provider(provider_id)

    with {:ok, claims} <- verify_state(state),
         :ok <- match_provider(claims["provider"], provider_id),
         {:ok, user_id} <- require_user_id(claims["uid"]),
         {:ok, mod} <- provider_module(provider_id),
         {:ok, tokens} <- mod.exchange_code(code),
         {:ok, identity} <- mod.fetch_identity(tokens.access_token),
         {:ok, access_enc} <- TokenVault.encrypt(tokens.access_token),
         {:ok, refresh_enc} <- maybe_encrypt(tokens[:refresh_token]),
         {:ok, connection} <-
           upsert_connection(user_id, provider_id, identity, tokens, access_enc, refresh_enc) do
      audit(connection.id, user_id, "user", user_id, "connected", nil, %{
        "provider" => provider_id,
        "login" => identity.external_account_login
      })

      ensure_default_bridge_grants!(connection)

      {:ok, Repo.preload(connection, :grants)}
    else
      {:error, reason} = err ->
        Logger.warning(
          "[Platforms] oauth complete failed provider=#{provider_id} reason=#{inspect(reason)}"
        )

        err

      other ->
        Logger.warning("[Platforms] oauth complete unexpected=#{inspect(other)}")
        {:error, :oauth_failed}
    end
  end

  def revoke_connection(user_id, connection_id)
      when is_binary(user_id) and is_binary(connection_id) do
    case get_connection(user_id, connection_id) do
      nil ->
        {:error, :not_found}

      %PlatformConnection{} = conn ->
        {:ok, updated} =
          conn
          |> PlatformConnection.changeset(%{
            status: "revoked",
            access_token_encrypted: nil,
            refresh_token_encrypted: nil,
            last_error: nil
          })
          |> Repo.update()

        from(g in ConnectionGrant, where: g.connection_id == ^conn.id)
        |> Repo.delete_all()

        audit(conn.id, user_id, "user", user_id, "revoked", nil, %{"provider" => conn.provider})
        {:ok, updated}
    end
  end


  def list_grants(user_id, connection_id) do
    case get_connection(user_id, connection_id) do
      nil -> {:error, :not_found}
      conn -> {:ok, conn.grants || []}
    end
  end

  def upsert_grant(user_id, connection_id, attrs) when is_map(attrs) do
    with %PlatformConnection{} = conn <- get_connection(user_id, connection_id) || :not_found,
         grantee_type when is_binary(grantee_type) <-
           normalize_grantee_type(attrs["grantee_type"] || attrs["granteeType"] || attrs[:grantee_type]),
         grantee_id when is_binary(grantee_id) <-
           normalize_grantee_id(attrs["grantee_id"] || attrs["granteeId"] || attrs[:grantee_id]),
         capabilities <-
           normalize_capabilities(
             attrs["capabilities"] || attrs[:capabilities],
             conn.provider
           ) do
      enabled =
        case attrs["enabled"] || attrs[:enabled] do
          false -> false
          "false" -> false
          _ -> true
        end

      existing =
        Repo.one(
          from g in ConnectionGrant,
            where:
              g.connection_id == ^conn.id and g.grantee_type == ^grantee_type and
                g.grantee_id == ^grantee_id
        )

      result =
        case existing do
          nil ->
            %ConnectionGrant{}
            |> ConnectionGrant.changeset(%{
              connection_id: conn.id,
              grantee_type: grantee_type,
              grantee_id: grantee_id,
              capabilities: capabilities,
              enabled: enabled
            })
            |> Repo.insert()

          grant ->
            grant
            |> ConnectionGrant.changeset(%{capabilities: capabilities, enabled: enabled})
            |> Repo.update()
        end

      case result do
        {:ok, grant} ->
          action = if is_nil(existing), do: "grant_created", else: "grant_updated"

          audit(conn.id, user_id, "user", user_id, action, nil, %{
            "grantee_type" => grantee_type,
            "grantee_id" => grantee_id,
            "capabilities" => capabilities
          })

          {:ok, grant}

        {:error, changeset} ->
          {:error, changeset}
      end
    else
      :not_found -> {:error, :not_found}
      nil -> {:error, :invalid_grantee}
      false -> {:error, :invalid_grantee}
    end
  end

  def revoke_grant(user_id, connection_id, grant_id) do
    with %PlatformConnection{} = conn <- get_connection(user_id, connection_id) || :not_found,
         %ConnectionGrant{} = grant <-
           Repo.one(
             from g in ConnectionGrant,
               where: g.id == ^grant_id and g.connection_id == ^conn.id
           ) || :not_found do
      {:ok, _} = Repo.delete(grant)

      audit(conn.id, user_id, "user", user_id, "grant_revoked", nil, %{
        "grant_id" => grant_id,
        "grantee_type" => grant.grantee_type,
        "grantee_id" => grant.grantee_id
      })

      :ok
    else
      :not_found -> {:error, :not_found}
    end
  end


  def list_usable_for_grantee(user_id, grantee_type, grantee_id)
      when is_binary(user_id) and is_binary(grantee_type) and is_binary(grantee_id) do
    _ = maybe_auto_grant_agent(user_id, grantee_type, grantee_id)

    Repo.all(
      from c in PlatformConnection,
        join: g in ConnectionGrant,
        on: g.connection_id == c.id,
        where:
          c.user_id == ^user_id and c.status == "active" and g.enabled == true and
            g.grantee_type == ^grantee_type and g.grantee_id == ^grantee_id,
        preload: [grants: g]
    )
    |> Enum.map(fn conn ->
      grant = List.first(conn.grants)

      %{
        connectionId: conn.id,
        provider: conn.provider,
        displayName: conn.display_name || conn.external_account_login,
        login: conn.external_account_login,
        capabilities: effective_capabilities(conn.provider, grant && grant.capabilities)
      }
    end)
  end

  @doc """
  Server-proxied platform action. Resolves grant → decrypt token → refresh if needed → invoke.
  Never returns tokens.
  """
  def invoke(user_id, grantee_type, grantee_id, attrs) when is_map(attrs) do
    provider = normalize_provider(attrs["provider"] || attrs[:provider])
    action = normalize_action(attrs["action"] || attrs[:action])
    params = attrs["params"] || attrs[:params] || %{}
    connection_id = attrs["connection_id"] || attrs["connectionId"] || attrs[:connection_id]

    _ = maybe_auto_grant_agent(user_id, grantee_type, grantee_id)

    with :ok <- require_provider_action(provider, action),
         {:ok, conn, grant} <-
           resolve_granted_connection(user_id, grantee_type, grantee_id, provider, connection_id),
         :ok <- ensure_capability_allowed(conn.provider, action, grant),
         {:ok, mod} <- provider_module(conn.provider),
         {:ok, access_token} <- access_token_for(conn),
         {:ok, data} <- mod.invoke_action(access_token, action, stringify_map(params)) do
      touch_used!(conn)

      audit(conn.id, user_id, grantee_type, grantee_id, "tool_call", action, %{
        "provider" => conn.provider,
        "ok" => true
      })

      {:ok,
       %{
         "ok" => true,
         "provider" => conn.provider,
         "action" => action,
         "connection_id" => conn.id,
         "data" => data
       }}
    else
      {:error, reason} = err ->
        maybe_audit_denied(user_id, grantee_type, grantee_id, provider, action, reason)
        err
    end
  end

  def prompt_guidance(user_id, grantee_type, grantee_id) do
    case list_usable_for_grantee(user_id, grantee_type, grantee_id) do
      [] ->
        nil

      items ->
        lines =
          Enum.map_join(items, "\n", fn item ->
            caps = Enum.join(item.capabilities, ", ")
            "- #{item.provider} (#{item.login || item.displayName}): #{caps}"
          end)

        """
        Platform connectors are connected for this run. Use `call_platform` for live actions.
        Never invent tokens or ask the user to paste API keys for these providers.
        Available:
        #{lines}
        Pass provider + action + params. For GitHub PR work use list_pull_requests, get_pull_request, list_pr_files, create_pr_comment.
        """
    end
  end


  def sign_state(claims) when is_map(claims) do
    Phoenix.Token.sign(VibeWeb.Endpoint, @state_salt, claims)
  end

  def verify_state(token) when is_binary(token) do
    case Phoenix.Token.verify(VibeWeb.Endpoint, @state_salt, token, max_age: @state_max_age_sec) do
      {:ok, claims} when is_map(claims) -> {:ok, claims}
      {:error, reason} -> {:error, reason}
    end
  end


  defp upsert_connection(user_id, provider_id, identity, tokens, access_enc, refresh_enc) do
    expires_at = expires_at_from(tokens[:expires_in])

    existing =
      Repo.one(
        from c in PlatformConnection,
          where:
            c.user_id == ^user_id and c.provider == ^provider_id and
              c.external_account_id == ^identity.external_account_id
      )

    attrs = %{
      user_id: user_id,
      provider: provider_id,
      external_account_id: identity.external_account_id,
      external_account_login: identity.external_account_login,
      display_name: identity.display_name,
      scopes: tokens[:scopes] || [],
      status: "active",
      access_token_encrypted: access_enc,
      refresh_token_encrypted: refresh_enc,
      token_expires_at: expires_at,
      metadata: identity.metadata || %{},
      last_error: nil
    }

    case existing do
      nil ->
        %PlatformConnection{}
        |> PlatformConnection.changeset(attrs)
        |> Repo.insert()

      conn ->
        conn
        |> PlatformConnection.changeset(attrs)
        |> Repo.update()
    end
  end

  defp ensure_default_bridge_grants!(%PlatformConnection{} = conn) do
    Enum.each(@bridge_agents, fn agent ->
      existing =
        Repo.one(
          from g in ConnectionGrant,
            where:
              g.connection_id == ^conn.id and g.grantee_type == "bridge_agent" and
                g.grantee_id == ^agent
        )

      if is_nil(existing) do
        %ConnectionGrant{}
        |> ConnectionGrant.changeset(%{
          connection_id: conn.id,
          grantee_type: "bridge_agent",
          grantee_id: agent,
          capabilities: [],
          enabled: true
        })
        |> Repo.insert()
      end
    end)

    :ok
  end

  defp resolve_granted_connection(user_id, grantee_type, grantee_id, provider, connection_id) do
    query =
      from c in PlatformConnection,
        join: g in ConnectionGrant,
        on: g.connection_id == c.id,
        where:
          c.user_id == ^user_id and c.status == "active" and c.provider == ^provider and
            g.enabled == true and g.grantee_type == ^grantee_type and g.grantee_id == ^grantee_id,
        select: {c, g}

    query =
      if is_binary(connection_id) and connection_id != "" do
        from [c, g] in query, where: c.id == ^connection_id
      else
        query
      end

    case Repo.all(query) do
      [] -> {:error, :no_grant}
      [{conn, grant}] -> {:ok, conn, grant}
      many ->
        {conn, grant} =
          Enum.max_by(many, fn {c, _} ->
            DateTime.to_unix(c.last_used_at || c.updated_at || c.inserted_at)
          end)

        {:ok, conn, grant}
    end
  end

  defp ensure_capability_allowed(provider, action, grant) do
    allowed = effective_capabilities(provider, grant && grant.capabilities)

    if action in allowed do
      :ok
    else
      {:error, {:capability_not_allowed, allowed}}
    end
  end

  defp effective_capabilities(provider, grant_caps) do
    all = Catalog.capability_ids(provider)

    case grant_caps do
      caps when is_list(caps) and caps != [] -> Enum.filter(caps, &(&1 in all))
      _ -> all
    end
  end

  defp access_token_for(%PlatformConnection{} = conn) do
    with {:ok, token} <- TokenVault.decrypt(conn.access_token_encrypted) do
      if token_expired?(conn) do
        refresh_connection(conn)
      else
        {:ok, token}
      end
    end
  end

  defp token_expired?(%PlatformConnection{token_expires_at: nil}), do: false

  defp token_expired?(%PlatformConnection{token_expires_at: expires_at}) do
    DateTime.compare(DateTime.add(DateTime.utc_now(), 60, :second), expires_at) != :lt
  end

  defp refresh_connection(%PlatformConnection{} = conn) do
    with {:ok, mod} <- provider_module(conn.provider),
         true <- function_exported?(mod, :refresh_tokens, 1) || {:error, :token_expired},
         {:ok, refresh} <- TokenVault.decrypt(conn.refresh_token_encrypted || ""),
         {:ok, tokens} <- mod.refresh_tokens(refresh),
         {:ok, access_enc} <- TokenVault.encrypt(tokens.access_token),
         {:ok, refresh_enc} <-
           maybe_encrypt(tokens[:refresh_token] || refresh) do
      {:ok, updated} =
        conn
        |> PlatformConnection.changeset(%{
          access_token_encrypted: access_enc,
          refresh_token_encrypted: refresh_enc,
          token_expires_at: expires_at_from(tokens[:expires_in]),
          status: "active",
          last_error: nil
        })
        |> Repo.update()

      audit(conn.id, conn.user_id, "system", "token_refresh", "refreshed", nil, %{
        "provider" => conn.provider
      })

      TokenVault.decrypt(updated.access_token_encrypted)
    else
      {:error, reason} ->
        _ =
          conn
          |> PlatformConnection.changeset(%{
            status: "expired",
            last_error: "token_refresh_failed"
          })
          |> Repo.update()

        {:error, reason}

      false ->
        {:error, :token_expired}
    end
  end

  defp touch_used!(%PlatformConnection{} = conn) do
    conn
    |> PlatformConnection.changeset(%{last_used_at: DateTime.utc_now() |> DateTime.truncate(:second)})
    |> Repo.update()
  end

  defp maybe_encrypt(nil), do: {:ok, nil}
  defp maybe_encrypt(""), do: {:ok, nil}
  defp maybe_encrypt(token) when is_binary(token), do: TokenVault.encrypt(token)

  defp expires_at_from(nil), do: nil
  defp expires_at_from(seconds) when is_integer(seconds) and seconds > 0 do
    DateTime.utc_now() |> DateTime.add(seconds, :second) |> DateTime.truncate(:second)
  end

  defp expires_at_from(_), do: nil

  defp provider_module(id) do
    case Catalog.provider_module(id) do
      nil -> {:error, :unknown_provider}
      mod -> {:ok, mod}
    end
  end

  defp maybe_auto_grant_agent(user_id, "agent", agent_id)
       when is_binary(user_id) and is_binary(agent_id) do
    if uuid?(agent_id) do
      alias Vibe.Agent, as: AgentSchema

      agent =
        Repo.one(
          from a in AgentSchema,
            where: a.id == ^agent_id and a.owner_user_id == ^user_id
        )

      tools = (agent && agent.enabled_tools) || []

      if agent && ("call_platform" in tools or "list_platform_connections" in tools) do
        connections =
          Repo.all(
            from c in PlatformConnection,
              where: c.user_id == ^user_id and c.status == "active"
          )

        Enum.each(connections, fn conn ->
          existing =
            Repo.one(
              from g in ConnectionGrant,
                where:
                  g.connection_id == ^conn.id and g.grantee_type == "agent" and
                    g.grantee_id == ^agent_id
            )

          if is_nil(existing) do
            %ConnectionGrant{}
            |> ConnectionGrant.changeset(%{
              connection_id: conn.id,
              grantee_type: "agent",
              grantee_id: agent_id,
              capabilities: [],
              enabled: true
            })
            |> Repo.insert()
          end
        end)
      end
    end

    :ok
  end

  defp maybe_auto_grant_agent(_, _, _), do: :ok

  defp uuid?(value) when is_binary(value) do
    match?(
      {:ok, _},
      Ecto.UUID.cast(value)
    )
  end

  defp uuid?(_), do: false

  defp require_oauth_configured(mod) do
    if mod.oauth_configured?(), do: :ok, else: {:error, :oauth_not_configured}
  end

  defp require_provider_action(provider, action)
       when is_binary(provider) and is_binary(action),
       do: :ok

  defp require_provider_action(_, _), do: {:error, :missing_provider_or_action}

  defp match_provider(claimed, expected) when is_binary(claimed) and is_binary(expected) do
    if String.downcase(claimed) == String.downcase(expected),
      do: :ok,
      else: {:error, :provider_mismatch}
  end

  defp match_provider(_, _), do: {:error, :provider_mismatch}

  defp require_user_id(uid) when is_binary(uid) and uid != "", do: {:ok, uid}
  defp require_user_id(_), do: {:error, :invalid_state}

  defp normalize_provider(id) when is_binary(id) do
    id |> String.trim() |> String.downcase()
  end

  defp normalize_provider(_), do: nil

  defp normalize_action(action) when is_binary(action) do
    action
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
    |> String.replace(" ", "_")
  end

  defp normalize_action(_), do: nil

  defp normalize_grantee_type(type) when is_binary(type) do
    case String.trim(type) |> String.downcase() do
      t when t in ["agent", "bridge_agent", "chat"] -> t
      "bridge" -> "bridge_agent"
      _ -> nil
    end
  end

  defp normalize_grantee_type(_), do: nil

  defp normalize_grantee_id(id) when is_binary(id) do
    case String.trim(id) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_grantee_id(_), do: nil

  defp normalize_capabilities(nil, _provider), do: []
  defp normalize_capabilities(caps, provider) when is_list(caps) do
    all = Catalog.capability_ids(provider)

    caps
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(&1 in all))
    |> Enum.uniq()
  end

  defp normalize_capabilities(_, _), do: []

  defp public_metadata(meta) when is_map(meta) do
    Map.take(meta, ["avatar_url", "html_url", "type"])
  end

  defp public_metadata(_), do: %{}

  defp stringify_map(map) when is_map(map) do
    Enum.into(map, %{}, fn {k, v} -> {to_string(k), v} end)
  end

  defp stringify_map(_), do: %{}

  defp nonce do
    Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
  end

  defp audit(connection_id, user_id, actor_type, actor_id, action, capability, detail) do
    %ConnectionAuditEvent{}
    |> ConnectionAuditEvent.changeset(%{
      connection_id: connection_id,
      user_id: user_id,
      actor_type: actor_type,
      actor_id: actor_id && to_string(actor_id),
      action: action,
      capability: capability,
      detail: detail || %{}
    })
    |> Repo.insert()
  rescue
    error ->
      Logger.warning("[Platforms] audit insert failed: #{inspect(error)}")
      {:error, error}
  end

  defp maybe_audit_denied(user_id, grantee_type, grantee_id, provider, action, reason) do
    audit(nil, user_id, grantee_type, grantee_id, "tool_denied", action, %{
      "provider" => provider,
      "reason" => inspect(reason)
    })
  end
end
