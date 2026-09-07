defmodule Vibe.Accounts do
  import Ecto.Query, warn: false
  import Plug.Crypto, only: [secure_compare: 2]
  require Logger
  alias Vibe.Repo
  alias Vibe.Accounts.TokenCache
  alias Vibe.Accounts.User
  alias Vibe.Accounts.UserBlock

  defmacrop normalized_phone_expr(phone_field) do
    quote do
      fragment("regexp_replace(COALESCE(?, ''), '[^0-9]', '', 'g')", unquote(phone_field))
    end
  end

  # SECURITY:
  @pbkdf2_iterations 600_000
  @legacy_pbkdf2_iterations 1_000
  @phone_min_digits 7
  @phone_max_digits 15
  @reserved_usernames ["vibeagent", "claude", "codex", "grok", "agy"]

  # SECURITY:
  @token_validity_seconds 30 * 24 * 60 * 60
  # Sliding-expiration cadence.
  @token_slide_after_seconds 24 * 60 * 60

  # Repo.get/2 raises on a nil id.
  def get_user(nil), do: nil
  def get_user(id), do: Repo.get(User, id)

  @privacy_fields %{
    "forwarded_messages" => :privacy_forward,
    "calls" => :privacy_calls,
    "phone_number" => :privacy_phone_number,
    "profile_photos" => :privacy_profile_photos,
    "bio" => :privacy_bio,
    "gifts" => :privacy_gifts,
    "birthday" => :privacy_birthday,
    "saved_music" => :privacy_saved_music
  }

  def privacy_settings(%User{} = user) do
    Map.new(@privacy_fields, fn {key, field} -> {key, Map.fetch!(user, field)} end)
  end

  def update_privacy_settings(%User{} = user, attrs) when is_map(attrs) do
    updates =
      Enum.reduce(attrs, %{}, fn {key, value}, acc ->
        case Map.fetch(@privacy_fields, to_string(key)) do
          {:ok, field} -> Map.put(acc, field, value)
          :error -> acc
        end
      end)

    update_user(user, updates)
  end

  @privacy_gate_fields [
    :privacy_phone_number,
    :privacy_profile_photos,
    :privacy_bio,
    :privacy_birthday,
    :privacy_gifts,
    :privacy_saved_music
  ]

  def viewer_can_see?(%User{} = owner, viewer, field) when field in @privacy_gate_fields do
    cond do
      match?(%{id: id} when id == owner.id, viewer) ->
        true

      true ->
        case Map.get(owner, field) || "everybody" do
          "everybody" -> true
          "nobody" -> false
          "contacts" -> dm_contact?(owner, viewer)
          _ -> false
        end
    end
  end

  def viewer_can_see?(_owner, _viewer, _field), do: false

  defp dm_contact?(_owner, nil), do: false

  defp dm_contact?(%User{id: owner_id}, %{id: viewer_id})
       when is_binary(viewer_id) and viewer_id != owner_id do
    not blocked?(owner_id, viewer_id) and not blocked?(viewer_id, owner_id) and
      dm_exists?(owner_id, viewer_id)
  end

  defp dm_contact?(_owner, _viewer), do: false

  defp dm_exists?(owner_id, viewer_id) do
    query =
      from(r in Vibe.Chat.Room,
        join: p1 in Vibe.Chat.Participant,
        on: p1.chat_id == r.id,
        join: p2 in Vibe.Chat.Participant,
        on: p2.chat_id == r.id,
        where: r.type == "dm" and p1.user_id == ^owner_id and p2.user_id == ^viewer_id,
        select: 1,
        limit: 1
      )

    Repo.exists?(query)
  end

  def get_user_by_token(token) when is_binary(token) and byte_size(token) > 0 do
    case TokenCache.fetch(hash_session_token(token)) do
      {:ok, user} -> {:ok, user}
      :miss -> resolve_user_by_token(token)
    end
  end

  def get_user_by_token(_token), do: {:error, :not_found}

  defp resolve_user_by_token(token) do
    case load_user_by_token(token) do
      {:ok, user} = ok ->
        TokenCache.put(hash_session_token(token), user)
        ok

      other ->
        other
    end
  end

  defp load_user_by_token(token) do
    case get_session_by_token(token) do
      {:ok, session} ->
        case get_user(session.user_id) do
          nil -> {:error, :not_found}
          %User{is_agent: true} -> {:error, :not_found}
          user -> {:ok, user}
        end

      {:error, :expired} ->
        {:error, :token_expired}

      _ ->
        load_user_by_legacy_token(token)
    end
  end

  defp load_user_by_legacy_token(token) do
    case Repo.get_by(User, login_token: token) do
      nil ->
        {:error, :not_found}

      %User{is_agent: true} ->
        {:error, :not_found}

      user ->
        if token_valid?(user) do
          legacy_token_hit(user)
          {:ok, maybe_slide_token_expiry(user)}
        else
          {:error, :token_expired}
        end
    end
  end

  defp legacy_token_hit(%User{id: user_id}) do
    :telemetry.execute([:vibe, :auth, :legacy_token_hit], %{count: 1}, %{user_id: user_id})
  end

  defp maybe_slide_token_expiry(%User{token_expires_at: nil} = user), do: user

  defp maybe_slide_token_expiry(%User{token_expires_at: expires_at} = user) do
    now = DateTime.utc_now()
    remaining = DateTime.diff(expires_at, now, :second)

    if remaining < @token_validity_seconds - @token_slide_after_seconds do
      new_expiry =
        now
        |> DateTime.add(@token_validity_seconds, :second)
        |> DateTime.truncate(:second)

      case update_user(user, %{"token_expires_at" => new_expiry}) do
        {:ok, updated} -> updated
        _ -> user
      end
    else
      user
    end
  end

  @doc """
  Check if token is still valid: not past its sliding expiry (or unset.
  """
  def token_valid?(%User{} = user) do
    expiry_ok? =
      case user.token_expires_at do
        nil -> true
        expires_at -> DateTime.compare(expires_at, DateTime.utc_now()) == :gt
      end

    expiry_ok? and not token_past_max_lifetime?(user)
  end

  defp token_past_max_lifetime?(%User{token_issued_at: nil}), do: false

  defp token_past_max_lifetime?(%User{token_issued_at: issued_at}) do
    DateTime.diff(DateTime.utc_now(), issued_at, :second) > token_max_lifetime_seconds()
  end

  @doc "Absolute token lifetime in seconds, from AUTH_TOKEN_MAX_LIFETIME_DAYS (default 90)."
  def token_max_lifetime_seconds do
    days =
      case Integer.parse(System.get_env("AUTH_TOKEN_MAX_LIFETIME_DAYS") || "90") do
        {value, _} when value > 0 -> value
        _ -> 90
      end

    days * 24 * 60 * 60
  end

  # Agents are invisible by username: only get_any_user_by_username/1 reaches them.
  def get_user_by_username(username) do
    lower_username = String.downcase(username)

    Repo.one(
      from(u in User,
        where: fragment("LOWER(?)", u.username) == ^lower_username and u.is_agent == false
      )
    )
  end

  @doc "Includes agent users. Only for callers that gate agent visibility themselves."
  def get_any_user_by_username(username) do
    lower_username = String.downcase(username)
    Repo.one(from(u in User, where: fragment("LOWER(?)", u.username) == ^lower_username))
  end

  def get_user_by_phone(phone_number) do
    case normalize_phone_number(phone_number) do
      nil ->
        nil

      normalized_phone ->
        Repo.one(
          from(u in User,
            where: normalized_phone_expr(u.phone_number) == ^normalized_phone,
            limit: 1
          )
        )
    end
  end

  def list_users_by_phone_numbers(phone_numbers, opts \\ []) when is_list(phone_numbers) do
    normalized_phones =
      phone_numbers
      |> Enum.map(&normalize_phone_number/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if normalized_phones == [] do
      []
    else
      exclude_id = Keyword.get(opts, :exclude_id)
      limit = Keyword.get(opts, :limit, 500)

      query =
        from(u in User,
          where:
            normalized_phone_expr(u.phone_number) in ^normalized_phones and u.is_agent == false,
          limit: ^limit
        )

      query =
        if exclude_id do
          from(u in query, where: u.id != ^exclude_id)
        else
          query
        end

      Repo.all(query)
    end
  end

  def normalize_phone_number(phone_number) when is_binary(phone_number) do
    normalized =
      phone_number
      |> String.trim()
      |> String.replace(~r/[^0-9]/, "")

    if normalized == "" or String.length(normalized) < @phone_min_digits or
         String.length(normalized) > @phone_max_digits do
      nil
    else
      normalized
    end
  end

  def normalize_phone_number(_), do: nil

  def username_exists?(username) do
    Repo.exists?(
      from(u in User, where: fragment("LOWER(?)", u.username) == ^String.downcase(username))
    )
  end

  def reserved_username?(username) when is_binary(username) do
    String.downcase(String.trim(username)) in @reserved_usernames
  end

  def reserved_username?(_), do: false

  def create_user(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  def update_user(%User{} = user, attrs) do
    user
    |> User.changeset(attrs)
    |> Repo.update()
    |> tap_invalidate_token_cache(user)
  end

  @doc "User-driven profile update — only the fields User.profile_changeset/2 casts."
  def update_profile(%User{} = user, attrs) do
    user
    |> User.profile_changeset(attrs)
    |> Repo.update()
    |> tap_invalidate_token_cache(user)
  end

  def delete_user(%User{} = user) do
    TokenCache.invalidate_user(user.id)
    if user.login_token, do: TokenCache.invalidate(hash_session_token(user.login_token))
    result = Repo.delete(user)
    if match?({:ok, _}, result), do: broadcast_disconnect(user.id)
    result
  end

  defp tap_invalidate_token_cache(result, %User{} = previous) do
    TokenCache.invalidate_user(previous.id)
    if previous.login_token, do: TokenCache.invalidate(hash_session_token(previous.login_token))
    result
  end

  defp broadcast_disconnect(user_id) do
    VibeWeb.Endpoint.broadcast("user_socket:#{user_id}", "disconnect", %{})
    :ok
  rescue
    error ->
      Logger.warning("[Accounts] Failed to broadcast disconnect user_id=#{user_id} error=#{inspect(error)}")
      :ok
  end

  @doc """
  Verify password against stored hash using PBKDF2.
  Supports both old (1000 iterations) and new (600,000 iterations) hashes.
  """
  def verify_password(password, stored_hash) do
    match?({:ok, _}, verify_password_with_info(password, stored_hash))
  end

  @doc """
  Verify password and return whether the hash uses current or legacy iterations.
  """
  def verify_password_with_info(password, stored_hash) do
    with {:ok, salt_bin, expected_hash_bin} <- parse_password_hash(stored_hash) do
      cond do
        verify_with_iterations(password, salt_bin, expected_hash_bin, @pbkdf2_iterations) ->
          {:ok, :current}

        verify_with_iterations(password, salt_bin, expected_hash_bin, @legacy_pbkdf2_iterations) ->
          {:ok, :legacy}

        true ->
          :error
      end
    else
      _ ->
        :error
    end
  end

  defp parse_password_hash(stored_hash) when is_binary(stored_hash) do
    with [salt_hex, hash_hex] <- String.split(stored_hash, ":", parts: 2),
         {:ok, salt_bin} <- Base.decode16(salt_hex, case: :mixed),
         {:ok, hash_bin} <- Base.decode16(hash_hex, case: :mixed) do
      {:ok, salt_bin, hash_bin}
    else
      _ -> :error
    end
  end

  defp parse_password_hash(_), do: :error

  defp verify_with_iterations(password, salt_bin, expected_hash_bin, iterations)
       when is_binary(expected_hash_bin) and byte_size(expected_hash_bin) > 0 do
    derived_bin =
      :crypto.pbkdf2_hmac(:sha512, password, salt_bin, iterations, byte_size(expected_hash_bin))

    secure_compare(derived_bin, expected_hash_bin)
  end

  defp verify_with_iterations(_password, _salt_bin, _expected_hash_bin, _iterations), do: false

  @doc """
  Migrate a user's password hash to the new iteration count.
  Call this after successful login with old hash.
  """
  def upgrade_password_hash(%User{} = user, password) do
    salt = :crypto.strong_rand_bytes(16)
    derived_bin = :crypto.pbkdf2_hmac(:sha512, password, salt, @pbkdf2_iterations, 64)

    new_hash =
      Base.encode16(salt, case: :lower) <> ":" <> Base.encode16(derived_bin, case: :lower)

    update_user(user, %{"password_hash" => new_hash})
  end

  def block_user(user_id, blocked_user_id) do
    %UserBlock{}
    |> UserBlock.changeset(%{user_id: user_id, blocked_user_id: blocked_user_id})
    |> Repo.insert()
  end

  def unblock_user(user_id, blocked_user_id) do
    query =
      from(ub in UserBlock,
        where: ub.user_id == ^user_id and ub.blocked_user_id == ^blocked_user_id
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      block -> Repo.delete(block)
    end
  end

  def list_blocked_users(user_id) do
    query =
      from(ub in UserBlock,
        join: u in User,
        on: u.id == ub.blocked_user_id,
        where: ub.user_id == ^user_id,
        select: u
      )

    Repo.all(query)
  end

  def blocked?(user_id, target_id) do
    query =
      from(ub in UserBlock,
        where: ub.user_id == ^user_id and ub.blocked_user_id == ^target_id
      )

    Repo.exists?(query)
  end


  alias Vibe.Schemas.AccountDevice
  alias Vibe.Schemas.DeviceSession
  alias Vibe.Schemas.DeviceLinkRequest

  @session_validity_seconds 30 * 24 * 60 * 60
  @link_request_validity_seconds 5 * 60

  @doc """
  Registers or refreshes the calling device and returns {:ok, account_device}.
  """
  def register_device(user_id, attrs, opts \\ []) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    identifier = attrs["device_identifier"] || attrs[:device_identifier]

    case Repo.get_by(AccountDevice, user_id: user_id, device_identifier: identifier) do
      nil ->
        %AccountDevice{}
        |> AccountDevice.changeset(
          Map.merge(stringify_keys(attrs), %{"user_id" => user_id, "last_seen_at" => now})
        )
        |> Repo.insert()

      existing ->
        refreshed =
          case Keyword.get(opts, :revive, false) do
            true -> %{"last_seen_at" => now, "revoked_at" => nil}
            false -> %{"last_seen_at" => now}
          end

        existing
        |> AccountDevice.changeset(Map.merge(stringify_keys(attrs), refreshed))
        |> Repo.update()
    end
  end

  @doc "Lists non-revoked devices for a user, most recently seen first."
  def list_devices(user_id) do
    AccountDevice
    |> where([d], d.user_id == ^user_id and is_nil(d.revoked_at))
    |> order_by([d], desc: d.last_seen_at)
    |> Repo.all()
  end

  @doc "Lists non-revoked sessions for a user, most recently used first."
  def list_sessions(user_id) do
    DeviceSession
    |> join(:inner, [s], d in AccountDevice, on: s.account_device_id == d.id)
    |> where([s, d], s.user_id == ^user_id and is_nil(s.revoked_at) and is_nil(d.revoked_at))
    |> order_by([s, d], desc: s.last_used_at, desc: s.inserted_at)
    |> preload([s, d], account_device: d)
    |> Repo.all()
  end

  @doc "Revokes a device and cascades revocation to its active sessions."
  def revoke_device(user_id, device_id) do
    case Repo.get_by(AccountDevice, id: device_id, user_id: user_id) do
      nil ->
        {:error, :not_found}

      device ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        result =
          Repo.transaction(fn ->
            {:ok, device} =
              device
              |> AccountDevice.changeset(%{"revoked_at" => now, "push_token_bundle" => %{}})
              |> Repo.update()

            {_count, _} =
              DeviceSession
              |> where([s], s.account_device_id == ^device_id and is_nil(s.revoked_at))
              |> Repo.update_all(set: [revoked_at: now])

            device
          end)

        Vibe.Audit.record(nil, "device.revoke", actor_user_id: user_id, target_id: device_id)
        TokenCache.invalidate_user(user_id)
        if match?({:ok, _}, result), do: broadcast_disconnect(user_id)
        result
    end
  end

  def revoke_device(user_id, device_id, current_device_identifier) do
    case Repo.get_by(AccountDevice, id: device_id, user_id: user_id) do
      nil -> {:error, :not_found}
      %{device_identifier: ^current_device_identifier} -> {:error, :current_session}
      _device -> revoke_device(user_id, device_id)
    end
  end

  @doc "Issues a device-scoped session token; returns {:ok, plaintext_token, session}."
  def create_device_session(user_id, account_device_id) do
    token = generate_session_token()
    token_hash = hash_session_token(token)
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    expires_at = DateTime.add(now, @session_validity_seconds, :second)

    result =
      Repo.transaction(fn ->
        DeviceSession
        |> where([s], s.account_device_id == ^account_device_id and is_nil(s.revoked_at))
        |> Repo.update_all(set: [revoked_at: now])

        case %DeviceSession{}
             |> DeviceSession.changeset(%{
               user_id: user_id,
               account_device_id: account_device_id,
               token_hash: token_hash,
               expires_at: expires_at
             })
             |> Repo.insert() do
          {:ok, session} -> {token, session}
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)

    case result do
      {:ok, {issued_token, session}} ->
        TokenCache.invalidate_user(user_id)
        {:ok, issued_token, session}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Registers a device and issues its replacement session token.
  """
  def issue_device_session(user_id, attrs) do
    with {:ok, device} <- register_device(user_id, attrs, revive: true),
         {:ok, token, session} <- create_device_session(user_id, device.id) do
      {:ok, token, session}
    end
  end

  @doc "Resolves a bearer token to its live session and records its use."
  def get_session_by_token(token) when is_binary(token) and byte_size(token) > 0 do
    token_hash = hash_session_token(token)

    Repo.transaction(fn ->
      case Repo.get_by(DeviceSession, token_hash: token_hash) do
        nil ->
          Repo.rollback(:not_found)

        session ->
          device =
            Repo.one(
              from(d in AccountDevice,
                where: d.id == ^session.account_device_id,
                lock: "FOR UPDATE"
              )
            )

          if is_nil(device) do
            Repo.rollback(:not_found)
          end

          locked_session =
            Repo.one(
              from(s in DeviceSession,
                where:
                  s.id == ^session.id and s.token_hash == ^token_hash and
                    s.account_device_id == ^device.id,
                lock: "FOR UPDATE"
              )
            )

          now = DateTime.utc_now()

          cond do
            is_nil(locked_session) ->
              Repo.rollback(:not_found)

            not is_nil(device.revoked_at) or not is_nil(locked_session.revoked_at) ->
              Repo.rollback(:revoked)

            device.user_id != locked_session.user_id ->
              Repo.rollback(:not_found)

            not DeviceSession.active?(locked_session, now) ->
              Repo.rollback(:expired)

            true ->
              touch_session_and_device(locked_session, device, now)
          end
      end
    end)
  end

  def get_session_by_token(_token), do: {:error, :not_found}

  defp touch_session_and_device(session, device, now) do
    truncated = DateTime.truncate(now, :second)

    with {:ok, updated_session} <-
           session
           |> DeviceSession.changeset(%{last_used_at: truncated})
           |> Repo.update(),
         {:ok, updated_device} <-
           device
           |> AccountDevice.changeset(%{last_seen_at: truncated})
           |> Repo.update() do
      %{updated_session | account_device: updated_device}
    else
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  @doc "Revokes a single device session (e.g. explicit sign-out)."
  def revoke_session(user_id, session_id) do
    case Repo.get_by(DeviceSession, id: session_id, user_id: user_id) do
      nil ->
        {:error, :not_found}

      session ->
        result =
          session
          |> DeviceSession.changeset(%{
            revoked_at: DateTime.utc_now() |> DateTime.truncate(:second)
          })
          |> Repo.update()

        TokenCache.invalidate_user(user_id)
        Vibe.Audit.record(nil, "session.revoke", actor_user_id: user_id, target_id: session_id)
        if match?({:ok, _}, result), do: broadcast_disconnect(user_id)
        result
    end
  end

  def revoke_session(user_id, session_id, current_device_identifier) do
    case Repo.get_by(DeviceSession, id: session_id, user_id: user_id)
         |> Repo.preload(:account_device) do
      nil ->
        {:error, :not_found}

      %{account_device: %{device_identifier: ^current_device_identifier}} ->
        {:error, :current_session}

      session ->
        revoke_session(user_id, session.id)
    end
  end

  @doc "Revokes the device session or legacy token used for this request."
  def revoke_bearer_token(%User{} = user, token) when is_binary(token) do
    token_hash = hash_session_token(token)

    case Repo.get_by(DeviceSession, token_hash: token_hash, user_id: user.id) do
      %DeviceSession{id: session_id} ->
        revoke_session(user.id, session_id)

      nil ->
        case Repo.get_by(User, id: user.id, login_token: token) do
          %User{} = holder -> revoke_login_token(holder)
          nil -> {:error, :not_found}
        end
    end
  end

  @doc "Clears the bearer login_token + its expiry/issued-at, and evicts the auth cache."
  def revoke_login_token(%User{} = user) do
    update_user(user, %{
      "login_token" => nil,
      "token_expires_at" => nil,
      "token_issued_at" => nil
    })
  end

  @doc "Revokes the login_token and every device session — sign-out everywhere."
  def revoke_all_sessions(%User{} = user) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    result =
      Repo.transaction(fn ->
        case revoke_login_token(user) do
          {:ok, updated} ->
            DeviceSession
            |> where([s], s.user_id == ^user.id and is_nil(s.revoked_at))
            |> Repo.update_all(set: [revoked_at: now])

            TokenCache.invalidate_user(user.id)
            updated

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)

    if match?({:ok, _}, result), do: broadcast_disconnect(user.id)
    result
  end

  @doc "Starts a pairing request from a not-yet-authenticated requester device."
  def start_link_request(attrs) do
    code = generate_pairing_code()
    code_hash = hash_session_token(code)
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    expires_at = DateTime.add(now, @link_request_validity_seconds, :second)

    case %DeviceLinkRequest{}
         |> DeviceLinkRequest.changeset(
           Map.merge(stringify_keys(attrs), %{
             "code_hash" => code_hash,
             "expires_at" => expires_at
           })
         )
         |> Repo.insert() do
      {:ok, request} -> {:ok, code, request}
      error -> error
    end
  end

  @doc "Looks up a pending, unexpired link request by its plaintext code."
  def get_pending_link_request(code) when is_binary(code) and byte_size(code) > 0 do
    code_hash = hash_session_token(code)

    DeviceLinkRequest
    |> Repo.get_by(code_hash: code_hash)
    |> pending_link_request(DateTime.utc_now())
  end

  def get_pending_link_request(_code), do: {:error, :not_found}

  @doc "Approves a pending link request."
  def approve_link_request(user_id, code, wrapped_key_envelope)
      when is_binary(code) and byte_size(code) > 0 do
    code_hash = hash_session_token(code)

    Repo.transaction(fn ->
      now = DateTime.utc_now()

      request =
        Repo.one(
          from(r in DeviceLinkRequest,
            where: r.code_hash == ^code_hash,
            lock: "FOR UPDATE"
          )
        )

      case pending_link_request(request, now) do
        {:ok, pending_request} ->
          case pending_request
               |> DeviceLinkRequest.approve_changeset(%{
                 user_id: user_id,
                 wrapped_key_envelope: wrapped_key_envelope,
                 approved_at: DateTime.truncate(now, :second)
               })
               |> Repo.update() do
            {:ok, approved_request} -> approved_request
            {:error, changeset} -> Repo.rollback(changeset)
          end

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  def approve_link_request(_user_id, _code, _wrapped_key_envelope) do
    {:error, :not_found}
  end

  defp pending_link_request(nil, _now), do: {:error, :not_found}

  defp pending_link_request(%DeviceLinkRequest{} = request, now) do
    cond do
      not is_nil(request.consumed_at) ->
        {:error, :consumed}

      not is_nil(request.rejected_at) ->
        {:error, :rejected}

      not match?(%DateTime{}, request.expires_at) ->
        {:error, :expired}

      DateTime.compare(request.expires_at, now) != :gt ->
        {:error, :expired}

      true ->
        {:ok, request}
    end
  end

  @doc "Claims a pairing code."
  def claim_link_request(code) when is_binary(code) and byte_size(code) > 0 do
    code_hash = hash_session_token(code)

    Repo.transaction(fn ->
      now = DateTime.utc_now()

      request =
        Repo.one(
          from(r in DeviceLinkRequest,
            where: r.code_hash == ^code_hash,
            lock: "FOR UPDATE"
          )
        )

      with {:ok, pending_request} <- pending_link_request(request, now),
           :ok <- claimable_link_request(pending_request),
           {:ok, consumed_request} <-
             pending_request
             |> DeviceLinkRequest.changeset(%{
               consumed_at: DateTime.truncate(now, :second)
             })
             |> Repo.update(),
           {:ok, device} <-
             register_device(
               pending_request.user_id,
               %{
                 "device_identifier" => pending_request.requester_device_identifier,
                 "name" => pending_request.requester_name,
                 "platform" => pending_request.requester_platform,
                 "public_key" => pending_request.requester_public_key
               },
               revive: true
             ),
           {:ok, token, session} <-
             create_device_session(pending_request.user_id, device.id) do
        %{
          user_id: pending_request.user_id,
          device: device,
          session: session,
          session_token: token,
          wrapped_key_envelope: consumed_request.wrapped_key_envelope
        }
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def claim_link_request(_code), do: {:error, :not_found}

  defp claimable_link_request(%DeviceLinkRequest{} = request) do
    if is_nil(request.approved_at) or is_nil(request.user_id) or
         is_nil(request.wrapped_key_envelope) do
      {:error, :not_approved}
    else
      :ok
    end
  end

  defp generate_session_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  defp generate_pairing_code do
    :crypto.strong_rand_bytes(6) |> Base.encode32(case: :upper, padding: false)
  end

  defp hash_session_token(token) do
    :crypto.hash(:sha256, token)
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      {to_string(k), if(is_map(v), do: stringify_keys(v), else: v)}
    end)
  end
end
