defmodule VibeWeb.UserController do
  use VibeWeb, :controller
  alias Vibe.Accounts
  alias Vibe.Agents
  alias VibeWeb.Presence
  require Logger
  @max_contact_match_numbers 500

  def show(conn, %{"id" => id}) do
    viewer = conn.assigns.current_user

    case Accounts.get_user(id) do
      nil -> not_found(conn)
      user -> if hidden_team_agent?(user, viewer), do: not_found(conn), else: render_user(conn, user, viewer)
    end
  end

  defp not_found(conn), do: conn |> put_status(404) |> json(%{error: "User not found"})

  # The built-in team is Vibegram staff, not a directory entry: only an admin sees it.
  defp hidden_team_agent?(%{id: id, is_agent: true}, viewer),
    do: is_nil(Vibe.Agents.get_agent_by_shadow_user(id)) and not Vibe.Admins.admin?(viewer)

  defp hidden_team_agent?(_user, _viewer), do: false

  def show_by_name(conn, %{"username" => username}) do
    case Accounts.get_user_by_username(username) do
      nil -> conn |> put_status(404) |> json(%{error: "User not found"})
      user -> render_user(conn, user, conn.assigns.current_user)
    end
  end

  def show_by_phone(conn, %{"phone" => phone}) do
    viewer = conn.assigns.current_user

    case Accounts.get_user_by_phone(phone) do
      nil ->
        conn |> put_status(404) |> json(%{error: "User not found"})

      user ->
        if Accounts.viewer_can_see?(user, viewer, :privacy_phone_number) do
          render_user(conn, user, viewer)
        else
          conn |> put_status(404) |> json(%{error: "User not found"})
        end
    end
  end

  def match_contacts(conn, %{"phoneNumbers" => phone_numbers}) when is_list(phone_numbers) do
    cond do
      phone_numbers == [] ->
        json(conn, %{matches: [], total: 0})

      length(phone_numbers) > @max_contact_match_numbers ->
        conn
        |> put_status(400)
        |> json(%{error: "Too many phone numbers. Max #{@max_contact_match_numbers} per request."})

      true ->
        current_user = conn.assigns.current_user

        matches =
          phone_numbers
          |> Accounts.list_users_by_phone_numbers(exclude_id: current_user.id, limit: @max_contact_match_numbers)
          |> Enum.reject(fn candidate ->
            Accounts.blocked?(current_user.id, candidate.id) or Accounts.blocked?(candidate.id, current_user.id)
          end)
          |> Enum.map(&render_contact_match(&1, current_user))

        json(conn, %{matches: matches, total: length(matches)})
    end
  end

  def match_contacts(conn, _params) do
    conn |> put_status(400) |> json(%{error: "phoneNumbers must be an array"})
  end

  def update_profile(conn, params) do
    id = params["userId"] || conn.assigns.current_user.id
    current_id = conn.assigns.current_user.id

    if id != current_id do
      conn |> put_status(:forbidden) |> json(%{error: "Forbidden"})
    else
      with {:ok, phone_attrs} <- normalize_phone_update(params) do
        push_token_update = resolve_push_token_update(params)

        update_attrs =
          %{}
          |> Map.merge(if params["profileImage"], do: %{profile_image: params["profileImage"]}, else: %{})
          |> Map.merge(if is_binary(push_token_update), do: %{push_token: push_token_update}, else: %{})
          |> Map.merge(phone_attrs)
          |> Map.merge(if params["name"], do: %{name: params["name"]}, else: %{})
          |> Map.merge(if params["username"], do: %{username: params["username"]}, else: %{})
          |> Map.merge(if Map.has_key?(params, "showLastSeen"), do: %{show_last_seen: params["showLastSeen"]}, else: %{})
          |> Map.merge(if Map.has_key?(params, "showOnlineStatus"), do: %{show_online_status: params["showOnlineStatus"]}, else: %{})
          |> Map.merge(if params["bio"], do: %{bio: params["bio"]}, else: %{})
          |> Map.merge(if Map.has_key?(params, "autoDeleteTimer"), do: %{auto_delete_timer: params["autoDeleteTimer"]}, else: %{})
          |> Map.merge(if Map.has_key?(params, "privacyForward"), do: %{privacy_forward: params["privacyForward"]}, else: %{})
          |> Map.merge(if Map.has_key?(params, "privacyCalls"), do: %{privacy_calls: params["privacyCalls"]}, else: %{})
          |> Map.merge(if Map.has_key?(params, "privacyPhoneNumber"), do: %{privacy_phone_number: params["privacyPhoneNumber"]}, else: %{})
          |> Map.merge(if Map.has_key?(params, "privacyProfilePhotos"), do: %{privacy_profile_photos: params["privacyProfilePhotos"]}, else: %{})
          |> Map.merge(if Map.has_key?(params, "privacyBio"), do: %{privacy_bio: params["privacyBio"]}, else: %{})
          |> Map.merge(if Map.has_key?(params, "privacyGifts"), do: %{privacy_gifts: params["privacyGifts"]}, else: %{})
          |> Map.merge(if Map.has_key?(params, "privacyBirthday"), do: %{privacy_birthday: params["privacyBirthday"]}, else: %{})
          |> Map.merge(if Map.has_key?(params, "privacySavedMusic"), do: %{privacy_saved_music: params["privacySavedMusic"]}, else: %{})
          |> Map.merge(if Map.has_key?(params, "dateOfBirth"), do: %{date_of_birth: params["dateOfBirth"]}, else: %{})

        with user when not is_nil(user) <- Accounts.get_user(id),
             merged_update_attrs <- merge_existing_push_token_update(update_attrs, user),
             {:ok, updated_user} <- apply_profile_update(user, merged_update_attrs) do
          if Map.has_key?(merged_update_attrs, :push_token) do
            Logger.info(
              "[UserController] push_token updated user_id=#{updated_user.id} targets=#{inspect(push_token_target_summary(updated_user.push_token))}"
            )
          end

          Vibe.Audit.record(conn, "profile.update", actor_user_id: updated_user.id)

          json(conn, %{
            success: true,
            userId: updated_user.id,
            username: updated_user.username,
            name: updated_user.name,
            profileImage: updated_user.profile_image,
            pushToken: updated_user.push_token,
            phoneNumber: updated_user.phone_number,
            showLastSeen: updated_user.show_last_seen,
            showOnlineStatus: updated_user.show_online_status,
            bio: updated_user.bio,
            autoDeleteTimer: updated_user.auto_delete_timer,
            privacyForward: updated_user.privacy_forward,
            privacyCalls: updated_user.privacy_calls,
            privacyPhoneNumber: updated_user.privacy_phone_number,
            privacyProfilePhotos: updated_user.privacy_profile_photos,
            privacyBio: updated_user.privacy_bio,
            privacyGifts: updated_user.privacy_gifts,
            privacyBirthday: updated_user.privacy_birthday,
            privacySavedMusic: updated_user.privacy_saved_music,
            dateOfBirth: updated_user.date_of_birth
          })
        else
          nil -> conn |> put_status(404) |> json(%{error: "User not found"})
          {:error, _changeset} -> conn |> put_status(400) |> json(%{error: "Invalid data"})
        end
      else
        {:error, msg} ->
          conn |> put_status(400) |> json(%{error: msg})
      end
    end
  end

  @identity_keys [:push_token, :phone_number, :username]

  defp apply_profile_update(user, attrs) do
    {identity_attrs, profile_attrs} = Map.split(attrs, @identity_keys)

    Vibe.Repo.transaction(fn ->
      with {:ok, user} <- apply_identity_attrs(user, identity_attrs),
           {:ok, user} <- apply_profile_attrs(user, profile_attrs) do
        user
      else
        {:error, changeset} -> Vibe.Repo.rollback(changeset)
      end
    end)
  end

  defp apply_identity_attrs(user, attrs) when map_size(attrs) == 0, do: {:ok, user}
  defp apply_identity_attrs(user, attrs), do: Accounts.update_user(user, attrs)

  defp apply_profile_attrs(user, attrs) when map_size(attrs) == 0, do: {:ok, user}
  defp apply_profile_attrs(user, attrs), do: Accounts.update_profile(user, attrs)

  defp resolve_push_token_update(params) when is_map(params) do
    explicit =
      cond do
        Map.has_key?(params, "pushToken") -> params["pushToken"]
        Map.has_key?(params, "push_token") -> params["push_token"]
        true -> nil
      end

    token_map =
      %{}
      |> merge_push_token_bundle(params["pushTokens"] || params["push_tokens"])
      |> maybe_put_token("fcm", params["fcmPushToken"] || params["fcm_push_token"])
      |> maybe_put_token("apns", params["apnsPushToken"] || params["apns_push_token"])
      |> maybe_put_token("apns_voip", params["voipPushToken"] || params["voip_push_token"])
      |> merge_explicit_push_token(explicit)

    cond do
      map_size(token_map) > 0 ->
        Jason.encode!(token_map)

      true ->
        nil
    end
  end

  defp resolve_push_token_update(_), do: nil

  defp merge_push_token_bundle(acc, value) when is_map(value) do
    acc
    |> maybe_put_token("fcm", value["fcm"] || value["fcmPushToken"])
    |> maybe_put_token("apns", value["apns"] || value["apnsToken"])
    |> maybe_put_token("apns_voip", value["apns_voip"] || value["voip"] || value["voipPushToken"])
  end

  defp merge_push_token_bundle(acc, value) when is_binary(value) do
    trimmed = value |> String.trim() |> unwrap_swift_optional()

    cond do
      trimmed == "" ->
        acc

      String.starts_with?(trimmed, "{") ->
        case Jason.decode(trimmed) do
          {:ok, decoded} when is_map(decoded) -> merge_push_token_bundle(acc, decoded)
          _ -> acc
        end

      true ->
        acc
    end
  end

  defp merge_push_token_bundle(acc, _), do: acc

  defp merge_explicit_push_token(acc, value) when is_binary(value) do
    trimmed = value |> String.trim() |> unwrap_swift_optional()

    cond do
      trimmed == "" ->
        acc

      String.starts_with?(trimmed, "{") ->
        merge_push_token_bundle(acc, trimmed)

      apns_device_token?(trimmed) ->
        maybe_put_token(acc, "apns", trimmed)

      true ->
        acc
    end
  end

  defp merge_explicit_push_token(acc, _), do: acc

  defp maybe_put_token(acc, _key, nil), do: acc

  defp maybe_put_token(acc, key, value) when is_binary(value) do
    trimmed = value |> String.trim() |> unwrap_swift_optional()
    if trimmed == "", do: acc, else: Map.put(acc, key, trimmed)
  end

  defp maybe_put_token(acc, _key, _value), do: acc

  defp unwrap_swift_optional(value) do
    case Regex.run(~r/^Optional\("(.*)"\)$/s, value) do
      [_, inner] -> String.trim(inner)
      _ -> value
    end
  end

  defp merge_existing_push_token_update(update_attrs, user) do
    case Map.fetch(update_attrs, :push_token) do
      {:ok, push_token_update} when is_binary(push_token_update) ->
        existing = push_token_to_map(user.push_token)
        incoming = push_token_to_map(push_token_update)

        merged =
          existing
          |> Map.merge(incoming)
          |> Enum.reject(fn {_key, value} -> !is_binary(value) or String.trim(value) == "" end)
          |> Map.new()

        if map_size(merged) > 0 do
          Map.put(update_attrs, :push_token, Jason.encode!(merged))
        else
          update_attrs
        end

      _ ->
        update_attrs
    end
  end

  defp push_token_to_map(token) when is_binary(token) do
    trimmed = String.trim(token)

    cond do
      trimmed == "" ->
        %{}

      String.starts_with?(trimmed, "{") ->
        case Jason.decode(trimmed) do
          {:ok, decoded} when is_map(decoded) ->
            %{}
            |> maybe_put_token("fcm", decoded["fcm"] || decoded["fcmPushToken"])
            |> maybe_put_token("apns", decoded["apns"] || decoded["apnsToken"])
            |> maybe_put_token("apns_voip", decoded["apns_voip"] || decoded["voip"] || decoded["voipPushToken"])

          _ ->
            %{}
        end

      true ->
        %{}
    end
  end

  defp push_token_to_map(_), do: %{}

  defp apns_device_token?(token) when is_binary(token) do
    length = String.length(token)

    length >= 64 and length <= 200 and rem(length, 2) == 0 and
      String.match?(token, ~r/\A[[:xdigit:]]+\z/)
  end

  defp apns_device_token?(_), do: false

  defp push_token_target_summary(token) do
    token
    |> push_token_to_map()
    |> Enum.map(fn {key, value} -> {key, String.length(value)} end)
    |> Map.new()
  end

  def delete(conn, _params) do
    id = conn.assigns.current_user.id

    case Accounts.get_user(id) do
      nil -> conn |> put_status(404) |> json(%{error: "User not found"})
      user ->
        case Accounts.delete_user(user) do
          {:ok, _} -> json(conn, %{success: true})
          {:error, _} -> conn |> put_status(400) |> json(%{error: "Failed to delete user"})
        end
    end
  end

  def block(conn, %{"blocked_user_id" => blocked_user_id}) do
    user_id = conn.assigns.current_user.id

    case Accounts.block_user(user_id, blocked_user_id) do
      {:ok, _} -> json(conn, %{success: true})
      {:error, _} -> conn |> put_status(400) |> json(%{error: "Failed to block user"})
    end
  end

  def unblock(conn, %{"blocked_user_id" => blocked_user_id}) do
    user_id = conn.assigns.current_user.id

    case Accounts.unblock_user(user_id, blocked_user_id) do
      {:ok, _} -> json(conn, %{success: true})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "Block not found"})
      {:error, _} -> conn |> put_status(400) |> json(%{error: "Failed to unblock user"})
    end
  end

  def list_blocks(conn, %{"id" => user_id}) do
    current_id = conn.assigns.current_user.id

    if user_id != current_id do
      conn |> put_status(:forbidden) |> json(%{error: "Forbidden"})
    else
      blocked_users = Accounts.list_blocked_users(current_id)
      json(conn, Enum.map(blocked_users, fn user ->
        %{
          userId: user.id,
          username: user.username,
          name: user.name,
          profileImage: user.profile_image
        }
      end))
    end
  end

  defp render_user(conn, user, viewer) do
    is_online = user.show_online_status and user_online?(user.id)
    agent_id = if user.is_agent, do: Agents.agent_id_for_user(user.id), else: nil

    json(conn, %{
      userId: user.id,
      username: user.username,
      shareLink: Vibe.Links.profile_url(user.username),
      isAgent: user.is_agent || false,
      tier: user.tier || "free",
      agentId: agent_id,
      acceptsIncomingChat:
        if(user.is_agent && agent_id, do: agent_accepts_incoming_chat(agent_id, viewer), else: nil),
      name: user.name,
      phoneNumber:
        if(Accounts.viewer_can_see?(user, viewer, :privacy_phone_number),
          do: user.phone_number,
          else: nil
        ),
      publicKey: user.public_key,
      identityKey: user.identity_key,
      profileImage:
        if(Accounts.viewer_can_see?(user, viewer, :privacy_profile_photos),
          do: user.profile_image,
          else: nil
        ),
      online: if(user.show_online_status, do: is_online, else: false),
      lastSeen: if(user.show_last_seen, do: user.last_seen, else: nil),
      showLastSeen: user.show_last_seen,
      showOnlineStatus: user.show_online_status,
      bio: if(Accounts.viewer_can_see?(user, viewer, :privacy_bio), do: user.bio, else: nil),
      autoDeleteTimer: user.auto_delete_timer,
      privacyForward: user.privacy_forward,
      privacyCalls: user.privacy_calls,
      privacyPhoneNumber: user.privacy_phone_number,
      privacyProfilePhotos: user.privacy_profile_photos,
      privacyBio: user.privacy_bio,
      privacyGifts: user.privacy_gifts,
      privacyBirthday: user.privacy_birthday,
      privacySavedMusic: user.privacy_saved_music,
      dateOfBirth:
        if(Accounts.viewer_can_see?(user, viewer, :privacy_birthday),
          do: user.date_of_birth,
          else: nil
        )
    })
  end

  defp user_online?(user_id) when is_binary(user_id) do
    map_size(Presence.list("user:#{user_id}")) > 0
  end

  defp user_online?(_), do: false

  defp render_contact_match(user, viewer) do
    agent_id = if user.is_agent, do: Agents.agent_id_for_user(user.id), else: nil

    %{
      userId: user.id,
      username: user.username,
      isAgent: user.is_agent || false,
      agentId: agent_id,
      acceptsIncomingChat:
        if(user.is_agent && agent_id, do: agent_accepts_incoming_chat(agent_id, viewer), else: nil),
      name: user.name,
      phoneNumber:
        if(Accounts.viewer_can_see?(user, viewer, :privacy_phone_number),
          do: user.phone_number,
          else: nil
        ),
      publicKey: user.public_key,
      identityKey: user.identity_key,
      profileImage:
        if(Accounts.viewer_can_see?(user, viewer, :privacy_profile_photos),
          do: user.profile_image,
          else: nil
        )
    }
  end

  defp normalize_phone_update(params) do
    if Map.has_key?(params, "phoneNumber") do
      case params["phoneNumber"] do
        nil ->
          {:ok, %{phone_number: nil}}

        phone when is_binary(phone) ->
          if String.trim(phone) == "" do
            {:ok, %{phone_number: nil}}
          else
            case Accounts.normalize_phone_number(phone) do
              nil -> {:error, "Invalid phone number format"}
              normalized_phone -> {:ok, %{phone_number: normalized_phone}}
            end
          end

        _ ->
          {:error, "Invalid phone number format"}
      end
    else
      {:ok, %{}}
    end
  end

  defp agent_accepts_incoming_chat(agent_id, viewer) do
    viewer_id =
      case viewer do
        %{id: id} -> id
        _ -> nil
      end

    case viewer_id && Agents.get_agent(agent_id, viewer_id) do
      %{} = agent -> Agents.incoming_chat_enabled?(agent)
      _ -> true
    end
  end
end
