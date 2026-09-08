defmodule VibeWeb.AuthController do
  use VibeWeb, :controller
  import Ecto.Query, warn: false
  require Logger
  alias Vibe.Accounts
  alias Vibe.Accounts.User

  # SECURITY:
  @pbkdf2_iterations 600_000

  # SECURITY:
  @token_validity_seconds 30 * 24 * 60 * 60

  # SECURITY:

  def register(conn, %{"username" => username, "password" => password, "deviceId" => device_id} = params) do
    username = username |> to_string() |> String.trim()
    password = to_string(password)
    normalized_phone = Accounts.normalize_phone_number(params["phoneNumber"])

    cond do
      String.length(username) < 3 ->
        conn |> put_status(400) |> json(%{error: "Username must be at least 3 characters"})

      String.length(username) > 30 ->
        conn |> put_status(400) |> json(%{error: "Username must be 30 characters or less"})

      not Regex.match?(~r/^[a-zA-Z0-9_]+$/, username) ->
        conn |> put_status(400) |> json(%{error: "Username can only contain letters, numbers, and underscores"})

      Accounts.reserved_username?(username) ->
        conn |> put_status(409) |> json(%{error: "username_taken"})

      String.length(password) < 8 ->
        conn |> put_status(400) |> json(%{error: "Password must be at least 8 characters"})

      Accounts.username_exists?(username) ->
        conn |> put_status(409) |> json(%{error: "username_taken"})

      params["phoneNumber"] && is_nil(normalized_phone) ->
        conn |> put_status(400) |> json(%{error: "Invalid phone number format"})

      normalized_phone && Accounts.get_user_by_phone(normalized_phone) ->
        conn |> put_status(409) |> json(%{error: "Phone number already in use"})

      true ->
        salt = :crypto.strong_rand_bytes(16)
        derived_bin = :crypto.pbkdf2_hmac(:sha512, password, salt, @pbkdf2_iterations, 64)
        password_hash = Base.encode16(salt, case: :lower) <> ":" <> Base.encode16(derived_bin, case: :lower)

        user_id = UUID.uuid4()

        lookup_value = present_credential(params["credential"]) || password
        secure_id = secure_id_for(hmac_secret!(), lookup_value)

        identity_version = params["identityKey"] || "v1"

        {public_key, encrypted_private_key} =
          cond do
            identity_version in ["v2", "v3"] && params["publicKey"] &&
                params["encryptedPrivateKey"] ->
              {params["publicKey"], params["encryptedPrivateKey"]}

            params["publicKey"] && params["encryptedPrivateKey"] ->
              {params["publicKey"], params["encryptedPrivateKey"]}



            true ->
              conn |> put_status(400) |> json(%{error: "Client must provide publicKey and encryptedPrivateKey for E2E encryption"})
              {:error, :missing_keys}
          end

        case {public_key, encrypted_private_key} do
          {:error, _} ->
            conn

          {pub_key, enc_priv_key} ->
            user_params = %{
              "id" => user_id,
              "username" => username,
              "password_hash" => password_hash,
              "device_id" => device_id,
              "public_key" => pub_key,
              "encrypted_private_key" => enc_priv_key,
              "identity_key" => identity_version,
              "secure_id" => secure_id,
              "phone_number" => normalized_phone
            }

            case Accounts.create_user(user_params) do
              {:ok, user} ->
                Vibe.Audit.record(conn, "register", actor_user_id: user.id)
                issue_login_response(conn, user, params)
              {:error, changeset} ->
                errors = Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
                  Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
                    opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
                  end)
                end)
                conn |> put_status(400) |> json(%{error: "Validation failed", details: errors})
            end
        end
    end
  end

  def login(conn, %{"credential" => credential, "password" => password} = params) do
    credential = credential |> to_string() |> String.trim()
    password = to_string(password)

    if Vibe.Accounts.LoginThrottle.locked?(credential) do
      Vibe.Audit.record(conn, "login.failure", metadata: %{username: credential})
      invalid_credentials(conn)
    else
      user =
        Accounts.get_user_by_username(credential) ||
          Accounts.get_user_by_phone(credential) ||
          get_user_by_secure_id(credential)

      case user do
        nil ->
          login_failed(conn, credential)

        %User{is_agent: true} ->
          login_failed(conn, credential)

        %User{} = u ->
          case Accounts.verify_password_with_info(password, u.password_hash) do
            {:ok, :current} ->
              login_succeeded(conn, credential, u)
              issue_login_response(conn, u, params)

            {:ok, :legacy} ->
              user_for_login =
                case Accounts.upgrade_password_hash(u, password) do
                  {:ok, upgraded_user} -> upgraded_user
                  _ -> u
                end

              login_succeeded(conn, credential, u)
              issue_login_response(conn, user_for_login, params)

            :error ->
              login_failed(conn, credential)
          end
      end
    end
  end

  # SECURITY:
  defp login_failed(conn, credential) do
    Vibe.Accounts.LoginThrottle.record_failure(credential)
    Vibe.Audit.record(conn, "login.failure", metadata: %{username: credential})
    invalid_credentials(conn)
  end

  defp login_succeeded(conn, credential, %User{} = user) do
    Vibe.Accounts.LoginThrottle.record_success(credential)
    Vibe.Audit.record(conn, "login.success", actor_user_id: user.id)
  end

  defp invalid_credentials(conn) do
    conn |> put_status(401) |> json(%{error: "invalid_credentials"})
  end

  @doc """
  Re-keys a pre-v3 account onto one-way-derived credentials.
  """
  def upgrade_identity(conn, params) do
    user = conn.assigns.current_user

    with credential when is_binary(credential) <- present_credential(params["credential"]),
         password when is_binary(password) <- present_credential(params["password"]) do
      salt = :crypto.strong_rand_bytes(16)
      derived_bin = :crypto.pbkdf2_hmac(:sha512, password, salt, @pbkdf2_iterations, 64)

      password_hash =
        Base.encode16(salt, case: :lower) <> ":" <> Base.encode16(derived_bin, case: :lower)

      case Accounts.update_user(user, %{
             "password_hash" => password_hash,
             "secure_id" => secure_id_for(hmac_secret!(), credential),
             "identity_key" => "v3"
           }) do
        {:ok, updated_user} ->
          Logger.info("[Auth] identity upgraded to v3 user_id=#{updated_user.id}")
          Vibe.Audit.record(conn, "identity.upgrade", actor_user_id: updated_user.id)
          json(conn, %{ok: true, secureId: updated_user.secure_id, identityKey: "v3"})

        {:error, _changeset} ->
          conn |> put_status(500) |> json(%{error: "Identity upgrade failed"})
      end
    else
      _ ->
        conn |> put_status(400) |> json(%{error: "credential and password are required"})
    end
  end

  @doc "POST /api/auth/logout — revokes only the login_token used for this session."
  def logout(conn, _params) do
    user = conn.assigns.current_user
    token = conn.assigns.current_auth_token

    case Accounts.revoke_bearer_token(user, token) do
      {:ok, _updated} ->
        Vibe.Audit.record(conn, "logout", actor_user_id: user.id)
        json(conn, %{ok: true})

      {:error, _reason} ->
        conn |> put_status(500) |> json(%{error: "logout_failed"})
    end
  end

  @doc "POST /api/auth/logout-all — revokes login_token and every device session."
  def logout_all(conn, _params) do
    user = conn.assigns.current_user

    case Accounts.revoke_all_sessions(user) do
      {:ok, _updated} ->
        Vibe.Audit.record(conn, "logout_all", actor_user_id: user.id)
        json(conn, %{ok: true})

      {:error, _changeset} ->
        conn |> put_status(500) |> json(%{error: "logout_failed"})
    end
  end

  defp present_credential(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present_credential(_), do: nil

  defp issue_login_response(conn, %User{} = user, params) do
    case present_credential(params["deviceId"]) do
      nil ->
        issue_legacy_login_response(conn, user)

      device_identifier ->
        attrs = %{
          "device_identifier" => device_identifier,
          "name" => present_credential(params["deviceName"]) || "Device",
          "platform" => present_credential(params["platform"]) || "unknown",
          "public_key" => user.public_key
        }

        case Accounts.issue_device_session(user.id, attrs) do
          {:ok, token, session} ->
            Accounts.revoke_login_token(user)
            render_login_response(conn, user, token, session.expires_at)

          {:error, _} ->
            conn |> put_status(500) |> json(%{error: "Failed to issue device session"})
        end
    end
  end

  defp issue_legacy_login_response(conn, %User{} = user) do
    token = UUID.uuid4()
    expires_at = DateTime.utc_now() |> DateTime.add(@token_validity_seconds, :second)

    case Accounts.update_user(user, %{
           "login_token" => token,
           "token_expires_at" => expires_at,
           "token_issued_at" => DateTime.utc_now() |> DateTime.truncate(:second)
         }) do
      {:ok, updated_user} -> render_login_response(conn, updated_user, token, expires_at)
      {:error, _} -> conn |> put_status(500) |> json(%{error: "Failed to issue session token"})
    end
  end

  defp render_login_response(conn, %User{} = user, token, expires_at) do
    json(conn, %{
      userId: user.id,
      username: user.username,
      secureId: user.secure_id,
      token: token,
      tokenExpiresAt: DateTime.to_iso8601(expires_at),
      publicKey: user.public_key,
      encryptedPrivateKey: user.encrypted_private_key,
      phoneNumber: user.phone_number
    })
  end

  defp hmac_secret! do
    System.get_env("VIBE_HMAC_SECRET")
    |> normalize_secret()
    |> case do
      nil ->
        raise "VIBE_HMAC_SECRET not set"

      secret ->
        secret
    end
  end

  defp legacy_hmac_secret do
    System.get_env("VIBE_HMAC_SECRET_LEGACY")
    |> normalize_secret()
  end

  defp normalize_secret(nil), do: nil

  defp normalize_secret(secret) when is_binary(secret) do
    secret = String.trim(secret)
    if secret == "", do: nil, else: secret
  end

  defp secure_id_candidates(value) when is_binary(value) do
    [hmac_secret!(), legacy_hmac_secret()]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.map(&secure_id_for(&1, value))
  end

  defp get_user_by_secure_id(credential) do
    secure_hashes = secure_id_candidates(credential)

    Vibe.Repo.one(
      from u in User,
        where: u.secure_id in ^secure_hashes,
        limit: 1
    )
  end

  defp secure_id_for(secret, value) when is_binary(secret) and is_binary(value) do
    :crypto.mac(:hmac, :sha256, secret, value)
    |> Base.encode16(case: :upper)
  end
end
