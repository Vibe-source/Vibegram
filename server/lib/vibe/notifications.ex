defmodule Vibe.Notifications do
  @moduledoc false

  require Logger

  alias Vibe.Accounts
  alias Vibe.Repo
  alias Vibe.Schemas.NotificationPreference

  @default_message_title "New message"
  @apns_voip_prod_base "https://api.push.apple.com"
  @apns_voip_sandbox_base "https://api.sandbox.push.apple.com"
  @fcm_legacy_url "https://fcm.googleapis.com/fcm/send"
  @apns_voip_jwt_cache_ttl_secs 50 * 60

  def get_notification_preferences(user_id) do
    case Repo.get_by(NotificationPreference, user_id: user_id) do
      nil -> NotificationPreference.default_preferences()
      preference -> NotificationPreference.normalize(preference.preferences)
    end
  end

  def update_notification_preferences(user_id, updates) do
    with {:ok, updates} <- NotificationPreference.validate_update(updates) do
      preferences = deep_merge(get_notification_preferences(user_id), updates)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      %NotificationPreference{}
      |> NotificationPreference.changeset(%{user_id: user_id, preferences: preferences})
      |> Repo.insert(
        on_conflict: [set: [preferences: preferences, updated_at: now]],
        conflict_target: [:user_id],
        returning: true
      )
      |> case do
        {:ok, preference} -> {:ok, NotificationPreference.normalize(preference.preferences)}
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  def notification_enabled?(user_id, category) do
    get_notification_preferences(user_id)
    |> Map.fetch!(category)
    |> Map.fetch!("enabled")
  end

  @doc """
  Collapse identity for one alert push.
  """
  @apns_collapse_id_max_bytes 64
  def push_collapse_id(data) when is_map(data) do
    (Map.get(data, :messageId) || Map.get(data, "messageId") || Map.get(data, :message_id) ||
       Map.get(data, "message_id"))
    |> to_string()
    |> String.trim()
    |> binary_part_prefix(@apns_collapse_id_max_bytes)
  end

  def push_collapse_id(_), do: ""

  defp binary_part_prefix(value, max_bytes) when is_binary(value) do
    if byte_size(value) <= max_bytes, do: value, else: binary_part(value, 0, max_bytes)
  end

  def send_incoming_call_push(to_user_id, payload)
      when is_binary(to_user_id) and is_map(payload) do
    with to_user when not is_nil(to_user) <- Accounts.get_user(to_user_id),
         push_targets when is_map(push_targets) <- normalized_push_targets(to_user.push_token) do
      call_type = normalize_call_type(payload["callType"] || payload["call_type"])
      call_id = payload["callId"] || payload["call_id"]
      from_user_id = payload["fromUserId"] || payload["from_user_id"]

      caller_name =
        payload["fromUserName"] || payload["from_user_name"] || from_user_id || "Unknown"

      caller_image =
        normalize_push_image(
          payload["fromUserImage"] || payload["from_user_image"],
          from_user_id
        )

      Logger.info(
        "[Notifications] Incoming call push routing to_user=#{to_user_id} call_id=#{inspect(call_id)} call_type=#{call_type} targets=#{inspect(describe_push_targets(push_targets))}"
      )

      base_data = %{
        event: "call-start",
        type: "call-start",
        callId: call_id,
        callType: call_type,
        fromUserId: from_user_id,
        fromUserName: caller_name,
        nativeCall: true
      }

      data =
        case caller_image do
          value when is_binary(value) and value != "" -> Map.put(base_data, :fromUserImage, value)
          _ -> base_data
        end

      voip_result =
        send_apns_voip_incoming_call_push(
          push_targets[:apns_voip],
          to_user_id,
          caller_name,
          call_type,
          data
        )

      fcm_result =
        send_fcm_incoming_call_push(
          push_targets[:fcm],
          to_user_id,
          caller_name,
          call_type,
          data
        )

      case {voip_result, fcm_result} do
        {{:ok, :apns_voip}, _} ->
          :ok

        {_, {:ok, :fcm}} ->
          :ok

        {:noop, :noop} ->
          Logger.info(
            "[Notifications] Incoming call push skipped: user has no usable push target to_user=#{to_user_id}"
          )

          :noop

        {voip, fcm} ->
          Logger.warning(
            "[Notifications] Incoming call push delivery failed to_user=#{to_user_id} apns_voip=#{inspect(voip)} fcm=#{inspect(fcm)}"
          )

          :error
      end
    else
      _ ->
        Logger.info(
          "[Notifications] Incoming call push skipped: target user missing or no stored push target to_user=#{to_user_id}"
        )

        :noop
    end
  end

  def send_incoming_call_push(_to_user_id, _payload), do: :noop

  def send_message_push(to_user_id, payload) when is_binary(to_user_id) and is_map(payload) do
    category = notification_category(payload)

    if notification_enabled?(to_user_id, category) do
      send_enabled_message_push(to_user_id, payload)
    else
      Logger.info(
        "[Notifications] Message push skipped: notification category muted to_user=#{to_user_id} category=#{category}"
      )

      :noop
    end
  end

  def send_message_push(_to_user_id, _payload), do: :noop

  defp send_enabled_message_push(to_user_id, payload) do
    case Accounts.get_user(to_user_id) do
      nil ->
        Logger.info(
          "[Notifications] Message push skipped: target user not found to_user=#{to_user_id}"
        )

        :noop

      to_user ->
        push_targets = normalized_push_targets(to_user.push_token)

        if has_message_push_target?(push_targets) do
          send_message_to_push_targets(to_user_id, payload, push_targets)
        else
          log_no_usable_message_push_target(to_user_id)
          :noop
        end
    end
  end

  defp send_message_to_push_targets(to_user_id, payload, push_targets) do
    from_user_id = payload["fromUserId"] || payload["from_user_id"] || payload["from_id"]
    sender = if is_binary(from_user_id), do: Accounts.get_user(from_user_id), else: nil
    sender_name_raw = (sender && (sender.name || sender.username)) || @default_message_title
    sender_name = truncate_text(sender_name_raw, 64)
    message_type = payload["type"] || "text"
    message_type_normalized = message_type |> to_string() |> String.downcase()
    message_body = resolve_message_body(payload, message_type)
    sender_image = normalize_push_image(sender && sender.profile_image, from_user_id)

    media_preview_image =
      if message_type_normalized in ["image", "video", "gif"] do
        resolve_push_media_image(payload)
      else
        nil
      end

    mutable_content_enabled =
      (is_binary(sender_image) and sender_image != "") or
        (is_binary(media_preview_image) and media_preview_image != "")

    base_data = %{
      type: "new_message",
      chatId: payload["chatId"] || payload["chat_id"],
      messageId: payload["messageId"] || payload["message_id"],
      fromUserId: from_user_id,
      fromUserName: sender_name,
      messageType: message_type
    }

    data_with_avatar =
      case sender_image do
        value when is_binary(value) and value != "" -> Map.put(base_data, :fromUserImage, value)
        _ -> base_data
      end

    data =
      case media_preview_image do
        value when is_binary(value) and value != "" ->
          data_with_avatar
          |> Map.put(:mediaImage, value)
          |> Map.put(:mediaUrl, value)

        _ ->
          data_with_avatar
      end

    Logger.info(
      "[Notifications] Sending message push to_user=#{to_user_id} chat_id=#{data.chatId} message_id=#{data.messageId} from_user=#{from_user_id} mutable_content=#{mutable_content_enabled} avatar_present=#{is_binary(sender_image) and sender_image != ""} media_preview_present=#{is_binary(media_preview_image) and media_preview_image != ""} message_type=#{message_type_normalized} targets=#{inspect(describe_push_targets(push_targets))}"
    )

    apns_result =
      send_apns_message_push(
        push_targets[:apns],
        to_user_id,
        sender_name,
        message_body,
        data,
        resolve_push_badge(payload),
        mutable_content_enabled
      )

    fcm_result =
      if apns_result == {:ok, :apns} do
        :noop
      else
        send_fcm_message_push(
          push_targets[:fcm],
          to_user_id,
          sender_name,
          message_body,
          data,
          resolve_push_badge(payload),
          mutable_content_enabled
        )
      end

    case {apns_result, fcm_result} do
      {{:ok, :apns}, _} ->
        :ok

      {_, {:ok, :fcm}} ->
        :ok

      {:noop, :noop} ->
        Logger.info(
          "[Notifications] Message push skipped: user has usable push tokens but no configured sender to_user=#{to_user_id}"
        )

        :noop

      {apns, fcm} ->
        Logger.warning(
          "[Notifications] Message push delivery failed: user has usable push tokens but all attempted sends failed to_user=#{to_user_id} apns=#{inspect(apns)} fcm=#{inspect(fcm)}"
        )

        :error
    end
  end

  defp notification_category(payload) do
    case payload["notificationCategory"] || payload["notification_category"] ||
           payload["chatType"] || payload["chat_type"] do
      category when category in ["group", "group_chat", "group_chats"] -> "groupChats"
      category when category in ["channel", "channels"] -> "channels"
      category when category in ["story", "stories"] -> "stories"
      category when category in ["reaction", "reactions"] -> "reactions"
      _ -> "privateChats"
    end
  end

  defp deep_merge(left, right) do
    Map.merge(left, right, fn _key, current, update ->
      if is_map(current) and is_map(update), do: deep_merge(current, update), else: update
    end)
  end

  defp send_fcm_incoming_call_push(fcm_token, _to_user_id, _caller_name, _call_type, _data)
       when not is_binary(fcm_token) do
    :noop
  end

  defp send_fcm_incoming_call_push(fcm_token, _to_user_id, _caller_name, _call_type, _data)
       when is_binary(fcm_token) and fcm_token == "" do
    :noop
  end

  defp send_fcm_incoming_call_push(fcm_token, to_user_id, caller_name, call_type, data) do
    case fcm_server_key() do
      nil ->
        Logger.info(
          "[Notifications] FCM call push skipped: missing FCM server key to_user=#{to_user_id}"
        )

        :noop

      server_key ->
        string_data =
          data
          |> stringify_push_data()
          |> Map.put("title", caller_name)
          |> Map.put("body", "Incoming #{call_type} call")

        message = %{
          to: fcm_token,
          priority: "high",
          content_available: true,
          data: string_data
        }

        request =
          Finch.build(
            :post,
            @fcm_legacy_url,
            [
              {"content-type", "application/json"},
              {"authorization", "key=#{server_key}"}
            ],
            Jason.encode!(message)
          )

        case Finch.request(request, Vibe.Finch, receive_timeout: 7_000) do
          {:ok, %Finch.Response{status: status, body: body}} when status in 200..299 ->
            Logger.info(
              "[Notifications] FCM call push accepted to_user=#{to_user_id} body=#{String.slice(body || "", 0, 240)}"
            )

            {:ok, :fcm}

          {:ok, %Finch.Response{status: status, body: body}} ->
            Logger.warning(
              "[Notifications] FCM call push failed status=#{status} to_user=#{to_user_id} body=#{String.slice(body || "", 0, 240)}"
            )

            :error

          {:error, reason} ->
            Logger.warning(
              "[Notifications] FCM call push request failed to_user=#{to_user_id} reason=#{inspect(reason)}"
            )

            :error
        end
    end
  end

  defp send_fcm_message_push(
         fcm_token,
         _to_user_id,
         _title,
         _body,
         _data,
         _badge,
         _mutable_content_enabled
       )
       when not is_binary(fcm_token) do
    :noop
  end

  defp send_fcm_message_push(
         fcm_token,
         _to_user_id,
         _title,
         _body,
         _data,
         _badge,
         _mutable_content_enabled
       )
       when fcm_token == "" do
    :noop
  end

  defp send_fcm_message_push(
         fcm_token,
         to_user_id,
         title,
         body,
         data,
         badge,
         _mutable_content_enabled
       ) do
    case fcm_server_key() do
      nil ->
        Logger.info(
          "[Notifications] FCM message push skipped: missing FCM server key to_user=#{to_user_id}"
        )

        :noop

      server_key ->
        message = %{
          to: fcm_token,
          priority: "high",
          content_available: true,
          mutable_content: true,
          notification: %{title: title, body: body, sound: "default", badge: badge},
          data: stringify_push_data(data)
        }

        request =
          Finch.build(
            :post,
            @fcm_legacy_url,
            [
              {"content-type", "application/json"},
              {"authorization", "key=#{server_key}"}
            ],
            Jason.encode!(message)
          )

        case Finch.request(request, Vibe.Finch, receive_timeout: 7_000) do
          {:ok, %Finch.Response{status: status, body: response_body}} when status in 200..299 ->
            Logger.info(
              "[Notifications] FCM message push accepted to_user=#{to_user_id} body=#{String.slice(response_body || "", 0, 240)}"
            )

            {:ok, :fcm}

          {:ok, %Finch.Response{status: status, body: response_body}} ->
            Logger.warning(
              "[Notifications] FCM message push failed status=#{status} to_user=#{to_user_id} body=#{String.slice(response_body || "", 0, 240)}"
            )

            :error

          {:error, reason} ->
            Logger.warning(
              "[Notifications] FCM message push request failed to_user=#{to_user_id} reason=#{inspect(reason)}"
            )

            :error
        end
    end
  end

  defp send_apns_message_push(
         apns_token,
         _to_user_id,
         _title,
         _body,
         _data,
         _badge,
         _mutable_content_enabled
       )
       when not is_binary(apns_token) do
    :noop
  end

  defp send_apns_message_push(
         apns_token,
         _to_user_id,
         _title,
         _body,
         _data,
         _badge,
         _mutable_content_enabled
       )
       when apns_token == "" do
    :noop
  end

  defp send_apns_message_push(
         apns_token,
         to_user_id,
         title,
         body,
         data,
         badge,
         _mutable_content_enabled
       ) do
    Logger.info(
      "[Notifications] APNs message push attempt to_user=#{to_user_id} message_id=#{inspect(Map.get(data, :messageId))} token=#{token_hint(apns_token)}"
    )

    with {:ok, config} <- apns_message_config(),
         {:ok, jwt} <- apns_voip_jwt(config),
         {:ok, request_body} <- apns_message_payload(data, title, body, badge) do
      headers =
        [
          {"content-type", "application/json"},
          {"authorization", "bearer " <> jwt},
          {"apns-push-type", "alert"},
          {"apns-priority", "10"},
          {"apns-topic", config.topic},
          {"apns-expiration", "0"},
          {"apns-collapse-id", push_collapse_id(data)}
        ]
        |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)

      post_apns_message(apns_token, to_user_id, config, headers, request_body, apns_base_urls())
    else
      {:error, :missing_config} ->
        Logger.info(
          "[Notifications] APNs message push skipped: missing APNs config #{inspect(apns_message_config_presence())} to_user=#{to_user_id}"
        )

        :noop

      {:error, reason} ->
        Logger.warning(
          "[Notifications] APNs message push setup failed to_user=#{to_user_id} reason=#{inspect(reason)}"
        )

        :error
    end
  end

  defp post_apns_message(_token, to_user_id, config, _headers, _body, []) do
    Logger.warning(
      "[Notifications] APNs message push failed in every environment to_user=#{to_user_id} topic=#{config.topic}"
    )

    :error
  end

  defp post_apns_message(token, to_user_id, config, headers, body, [base_url | rest]) do
    request = Finch.build(:post, "#{base_url}/3/device/#{URI.encode(token)}", headers, body)

    case Finch.request(request, Vibe.APNsFinch, receive_timeout: 7_000) do
      {:ok, %Finch.Response{status: 200}} ->
        Logger.info(
          "[Notifications] APNs message push accepted to_user=#{to_user_id} topic=#{config.topic} base_url=#{base_url}"
        )

        {:ok, :apns}

      {:ok, %Finch.Response{status: 400, body: response_body}} ->
        if rest != [] and String.contains?(response_body || "", "BadDeviceToken") do
          Logger.info(
            "[Notifications] APNs token is not for #{base_url}, retrying the other environment to_user=#{to_user_id}"
          )

          post_apns_message(token, to_user_id, config, headers, body, rest)
        else
          log_apns_message_failure(to_user_id, config, base_url, 400, response_body)
          :error
        end

      {:ok, %Finch.Response{status: status, body: response_body}} ->
        log_apns_message_failure(to_user_id, config, base_url, status, response_body)
        :error

      {:error, reason} ->
        Logger.warning(
          "[Notifications] APNs message push request failed to_user=#{to_user_id} topic=#{config.topic} base_url=#{base_url} reason=#{inspect(reason)}"
        )

        :error
    end
  end

  defp log_apns_message_failure(to_user_id, config, base_url, status, response_body) do
    Logger.warning(
      "[Notifications] APNs message push failed status=#{status} to_user=#{to_user_id} topic=#{config.topic} base_url=#{base_url} body=#{String.slice(response_body || "", 0, 240)}"
    )
  end

  defp send_apns_voip_incoming_call_push(voip_token, _to_user_id, _caller_name, _call_type, _data)
       when not is_binary(voip_token) do
    :noop
  end

  defp send_apns_voip_incoming_call_push(voip_token, _to_user_id, _caller_name, _call_type, _data)
       when is_binary(voip_token) and voip_token == "" do
    :noop
  end

  defp send_apns_voip_incoming_call_push(voip_token, to_user_id, caller_name, call_type, data) do
    call_id = Map.get(data, :callId, nil) |> to_string()
    token_hint = token_hint(voip_token)

    Logger.info(
      "[Notifications] APNs VoIP attempt to_user=#{to_user_id} call_id=#{inspect(call_id)} call_type=#{call_type} token=#{token_hint}"
    )

    with {:ok, config} <- apns_voip_config(),
         {:ok, jwt} <- apns_voip_jwt(config),
         {:ok, body} <- apns_voip_payload(data, caller_name, call_type) do
      url = "#{config.base_url}/3/device/#{URI.encode(voip_token)}"

      headers =
        [
          {"content-type", "application/json"},
          {"authorization", "bearer " <> jwt},
          {"apns-push-type", "voip"},
          {"apns-priority", "10"},
          {"apns-topic", config.topic},
          {"apns-expiration", "0"},
          {"apns-collapse-id", Map.get(data, :callId, "") |> to_string()}
        ]
        |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)

      request = Finch.build(:post, url, headers, body)

      case Finch.request(request, Vibe.APNsFinch, receive_timeout: 7_000) do
        {:ok, %Finch.Response{status: 200}} ->
          Logger.info(
            "[Notifications] APNs VoIP push accepted to_user=#{to_user_id} call_type=#{call_type} topic=#{config.topic} base_url=#{config.base_url}"
          )

          {:ok, :apns_voip}

        {:ok, %Finch.Response{status: status, body: response_body}} ->
          Logger.warning(
            "[Notifications] APNs VoIP push failed status=#{status} to_user=#{to_user_id} topic=#{config.topic} base_url=#{config.base_url} body=#{String.slice(response_body || "", 0, 240)}"
          )

          :error

        {:error, reason} ->
          Logger.warning(
            "[Notifications] APNs VoIP request failed to_user=#{to_user_id} topic=#{config.topic} base_url=#{config.base_url} reason=#{inspect(reason)}"
          )

          :error
      end
    else
      {:error, :missing_config} ->
        Logger.info(
          "[Notifications] APNs VoIP push skipped: missing APNs VoIP config #{inspect(apns_voip_config_presence())}"
        )

        :noop

      {:error, reason} ->
        Logger.warning(
          "[Notifications] APNs VoIP push setup failed to_user=#{to_user_id} reason=#{inspect(reason)}"
        )

        :error
    end
  end

  defp normalized_push_targets(token) when is_binary(token) do
    trimmed = String.trim(token)

    cond do
      trimmed == "" ->
        nil

      true ->
        case Jason.decode(trimmed) do
          {:ok, value} when is_map(value) ->
            %{
              fcm: normalize_token_value(value["fcm"] || value["fcmPushToken"]),
              apns: normalize_token_value(value["apns"] || value["apnsToken"]),
              apns_voip:
                normalize_token_value(
                  value["apns_voip"] || value["voip"] || value["voipPushToken"]
                )
            }

          _ ->
            %{fcm: nil, apns: nil, apns_voip: nil}
        end
    end
  end

  defp normalized_push_targets(_), do: nil

  defp has_message_push_target?(push_targets) when is_map(push_targets) do
    Enum.any?([push_targets[:apns], push_targets[:fcm]], &usable_push_token?/1)
  end

  defp has_message_push_target?(_), do: false

  defp usable_push_token?(value) when is_binary(value), do: String.trim(value) != ""
  defp usable_push_token?(_), do: false

  defp log_no_usable_message_push_target(to_user_id) do
    Logger.info(
      "[Notifications] Message push skipped: user has no usable push target to_user=#{to_user_id}"
    )
  end

  defp fcm_server_key do
    System.get_env("FCM_SERVER_KEY")
    |> normalize_token_value()
    |> case do
      nil ->
        System.get_env("FIREBASE_SERVER_KEY")
        |> normalize_token_value()

      value ->
        value
    end
    |> case do
      nil ->
        System.get_env("FIREBASE_CLOUD_MESSAGING_SERVER_KEY")
        |> normalize_token_value()

      value ->
        value
    end
  end

  defp stringify_push_data(data) when is_map(data) do
    data
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      string_value =
        case value do
          nil -> nil
          value when is_binary(value) -> value
          value when is_atom(value) -> Atom.to_string(value)
          value -> to_string(value)
        end

      if is_binary(string_value) and string_value != "" do
        Map.put(acc, to_string(key), string_value)
      else
        acc
      end
    end)
  end

  defp stringify_push_data(_), do: %{}

  defp normalize_token_value(value) when is_binary(value) do
    case value |> String.trim() |> unwrap_swift_optional() do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_token_value(_), do: nil

  defp unwrap_swift_optional(value) do
    case Regex.run(~r/^Optional\("(.*)"\)$/s, value) do
      [_, inner] -> String.trim(inner)
      _ -> value
    end
  end

  defp describe_push_targets(push_targets) when is_map(push_targets) do
    %{
      fcm: token_hint(push_targets[:fcm]),
      apns: token_hint(push_targets[:apns]),
      apns_voip: token_hint(push_targets[:apns_voip])
    }
  end

  defp token_hint(token) when is_binary(token) do
    trimmed = String.trim(token)

    cond do
      trimmed == "" ->
        "empty"

      String.length(trimmed) <= 12 ->
        "len=#{String.length(trimmed)}"

      true ->
        prefix = String.slice(trimmed, 0, 6)
        suffix = String.slice(trimmed, -4, 4)
        "len=#{String.length(trimmed)} #{prefix}...#{suffix}"
    end
  end

  defp token_hint(_), do: "missing"

  defp apns_voip_config_presence do
    env_value = String.downcase(System.get_env("APPLE_VOIP_APNS_ENV") || "")

    %{
      team_id: is_binary(normalize_token_value(System.get_env("APPLE_VOIP_TEAM_ID"))),
      key_id: is_binary(normalize_token_value(System.get_env("APPLE_VOIP_KEY_ID"))),
      private_key:
        is_binary(normalize_apns_private_key(System.get_env("APPLE_VOIP_PRIVATE_KEY"))),
      topic:
        is_binary(
          System.get_env("APPLE_VOIP_TOPIC") |> normalize_token_value() ||
            case System.get_env("APPLE_BUNDLE_ID") |> normalize_token_value() do
              nil -> nil
              bundle_id -> bundle_id <> ".voip"
            end
        ),
      env: if(env_value in ["sandbox", "development", "dev"], do: "sandbox", else: "production")
    }
  end

  defp apns_voip_config do
    team_id = System.get_env("APPLE_VOIP_TEAM_ID") |> normalize_token_value()
    key_id = System.get_env("APPLE_VOIP_KEY_ID") |> normalize_token_value()

    private_key =
      System.get_env("APPLE_VOIP_PRIVATE_KEY")
      |> normalize_apns_private_key()

    topic =
      System.get_env("APPLE_VOIP_TOPIC") |> normalize_token_value() ||
        case System.get_env("APPLE_BUNDLE_ID") |> normalize_token_value() do
          nil -> nil
          bundle_id -> bundle_id <> ".voip"
        end

    base_url = apns_base_url()

    if is_binary(team_id) and is_binary(key_id) and is_binary(private_key) and is_binary(topic) do
      {:ok,
       %{
         team_id: team_id,
         key_id: key_id,
         private_key: private_key,
         topic: topic,
         base_url: base_url
       }}
    else
      {:error, :missing_config}
    end
  end

  defp apns_message_config_presence do
    %{
      team_id: is_binary(normalize_token_value(System.get_env("APPLE_VOIP_TEAM_ID"))),
      key_id: is_binary(normalize_token_value(System.get_env("APPLE_VOIP_KEY_ID"))),
      private_key:
        is_binary(normalize_apns_private_key(System.get_env("APPLE_VOIP_PRIVATE_KEY"))),
      topic: is_binary(normalize_token_value(System.get_env("APPLE_BUNDLE_ID"))),
      env: apns_environment()
    }
  end

  defp apns_message_config do
    team_id = System.get_env("APPLE_VOIP_TEAM_ID") |> normalize_token_value()
    key_id = System.get_env("APPLE_VOIP_KEY_ID") |> normalize_token_value()

    private_key =
      System.get_env("APPLE_VOIP_PRIVATE_KEY")
      |> normalize_apns_private_key()

    topic = System.get_env("APPLE_BUNDLE_ID") |> normalize_token_value()

    if is_binary(team_id) and is_binary(key_id) and is_binary(private_key) and is_binary(topic) do
      {:ok,
       %{
         team_id: team_id,
         key_id: key_id,
         private_key: private_key,
         topic: topic,
         base_url: apns_base_url()
       }}
    else
      {:error, :missing_config}
    end
  end

  defp apns_environment do
    case String.downcase(System.get_env("APPLE_VOIP_APNS_ENV") || "") do
      value when value in ["sandbox", "development", "dev"] -> "sandbox"
      _ -> "production"
    end
  end

  defp apns_base_url do
    case apns_environment() do
      "sandbox" -> @apns_voip_sandbox_base
      _ -> @apns_voip_prod_base
    end
  end

  defp apns_base_urls do
    case apns_base_url() do
      @apns_voip_sandbox_base -> [@apns_voip_sandbox_base, @apns_voip_prod_base]
      base -> [base, @apns_voip_sandbox_base]
    end
  end

  defp normalize_apns_private_key(value) when is_binary(value) do
    trimmed = String.trim(value)

    normalized =
      trimmed
      |> String.replace("\\r\\n", "\n")
      |> String.replace("\\n", "\n")
      |> String.replace("\\r", "\n")

    if normalized == "", do: nil, else: normalized
  end

  defp normalize_apns_private_key(_), do: nil

  defp apns_voip_jwt(config) do
    now = System.system_time(:second)
    cache_key = apns_voip_jwt_cache_key(config)

    case :persistent_term.get(cache_key, nil) do
      %{jwt: jwt, iat: iat}
      when is_binary(jwt) and is_integer(iat) and now - iat < @apns_voip_jwt_cache_ttl_secs ->
        {:ok, jwt}

      _ ->
        header = %{"alg" => "ES256", "kid" => config.key_id}
        claims = %{"iss" => config.team_id, "iat" => now}

        signing_input =
          base64url_encode(Jason.encode!(header)) <>
            "." <> base64url_encode(Jason.encode!(claims))

        with {:ok, private_key} <- decode_apns_private_key(config.private_key),
             {:ok, signature} <- sign_es256_jwt(signing_input, private_key) do
          jwt = signing_input <> "." <> base64url_encode(signature)
          :persistent_term.put(cache_key, %{jwt: jwt, iat: now})
          {:ok, jwt}
        end
    end
  end

  defp apns_voip_jwt_cache_key(config) do
    {:vibe_notifications_apns_voip_jwt, config.team_id, config.key_id,
     :erlang.phash2(config.private_key)}
  end

  defp decode_apns_private_key(pem) when is_binary(pem) do
    try do
      case :public_key.pem_decode(pem) do
        [entry | _] ->
          {:ok, :public_key.pem_entry_decode(entry)}

        _ ->
          {:error, :invalid_apns_private_key_pem}
      end
    rescue
      error -> {:error, {:invalid_apns_private_key_pem, error}}
    end
  end

  defp sign_es256_jwt(signing_input, private_key) do
    try do
      der_sig = :public_key.sign(signing_input, :sha256, private_key)

      case :public_key.der_decode(:"ECDSA-Sig-Value", der_sig) do
        {:"ECDSA-Sig-Value", r, s} when is_integer(r) and is_integer(s) ->
          {:ok, <<int_to_fixed_32(r)::binary, int_to_fixed_32(s)::binary>>}

        {r, s} when is_integer(r) and is_integer(s) ->
          {:ok, <<int_to_fixed_32(r)::binary, int_to_fixed_32(s)::binary>>}

        _ ->
          {:error, :invalid_apns_signature}
      end
    rescue
      error -> {:error, {:apns_sign_failed, error}}
    end
  end

  defp int_to_fixed_32(int) when is_integer(int) and int >= 0 do
    bin = :binary.encode_unsigned(int)

    case byte_size(bin) do
      32 -> bin
      size when size < 32 -> :binary.copy(<<0>>, 32 - size) <> bin
      size when size > 32 -> binary_part(bin, size - 32, 32)
    end
  end

  defp apns_voip_payload(data, caller_name, call_type) when is_map(data) do
    aps = %{"content-available" => 1}

    payload =
      data
      |> Map.put_new(:event, "call-start")
      |> Map.put_new(:type, "call-start")
      |> Map.put_new(:nativeCall, true)
      |> Map.put(:callerLabel, caller_name)
      |> Map.put(:callType, if(call_type == "video", do: "video", else: "voice"))
      |> Map.put(:aps, aps)

    {:ok, Jason.encode!(payload)}
  rescue
    error -> {:error, {:apns_payload_encode_failed, error}}
  end

  defp apns_message_payload(data, title, body, badge) when is_map(data) do
    aps = %{
      "alert" => %{"title" => title, "body" => body},
      "sound" => "default",
      "badge" => badge,
      "mutable-content" => 1
    }

    payload = Map.put(data, :aps, aps)
    {:ok, Jason.encode!(payload)}
  rescue
    error -> {:error, {:apns_payload_encode_failed, error}}
  end

  defp base64url_encode(binary) when is_binary(binary) do
    Base.url_encode64(binary, padding: false)
  end

  defp normalize_call_type(value) when is_binary(value) do
    if String.downcase(value) == "video", do: "video", else: "voice"
  end

  defp normalize_call_type(_), do: "voice"

  defp resolve_message_body(payload, message_type) do
    body =
      case payload["body"] || payload["text"] do
        value when is_binary(value) -> String.trim(value)
        _ -> ""
      end

    if body != "" do
      truncate_text(body, 160)
    else
      kind = payload["pushKind"] || payload["push_kind"] || message_type

      case to_string(kind || "text") do
        "image" -> "Photo"
        "video" -> "Video"
        "voice" -> "Voice message"
        "music" -> "Audio"
        "file" -> "File"
        "location" -> "Location"
        "contact" -> "Contact"
        "gif" -> "GIF"
        "sticker" -> "Sticker"
        "text" -> "New message"
        _ -> "New message"
      end
    end
  end

  defp resolve_push_badge(payload) when is_map(payload) do
    case payload["badge"] || payload[:badge] do
      value when is_integer(value) and value >= 0 ->
        value

      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {badge, ""} when badge >= 0 -> badge
          _ -> 1
        end

      _ ->
        1
    end
  end

  defp resolve_push_badge(_), do: 1

  defp resolve_push_media_image(payload) when is_map(payload) do
    candidate =
      payload["media_image"] ||
        payload["mediaImage"] ||
        payload["media_url"] ||
        payload["mediaUrl"] ||
        map_value(payload["richContent"], "image") ||
        map_value(payload["_richContent"], "image")

    case candidate do
      value when is_binary(value) ->
        trimmed = String.trim(value)

        cond do
          trimmed == "" ->
            nil

          String.starts_with?(String.downcase(trimmed), ["http://", "https://"]) ->
            if String.length(trimmed) <= 2048 do
              trimmed
            else
              Logger.warning(
                "[Notifications] media preview image URL too long length=#{String.length(trimmed)}"
              )

              nil
            end

          true ->
            nil
        end

      _ ->
        nil
    end
  end

  defp resolve_push_media_image(_), do: nil

  defp map_value(value, key) when is_map(value), do: value[key]
  defp map_value(_value, _key), do: nil

  defp truncate_text(text, max_len) when is_binary(text) and is_integer(max_len) do
    if String.length(text) > max_len do
      String.slice(text, 0, max_len - 1) <> "…"
    else
      text
    end
  end

  defp normalize_push_image(value, from_user_id) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        Logger.info("[Notifications] push image skipped empty from_user=#{from_user_id}")
        nil

      String.starts_with?(String.downcase(trimmed), ["http://", "https://"]) ->
        if String.length(trimmed) <= 1024 do
          Logger.info("[Notifications] push image using remote URL from_user=#{from_user_id}")
          trimmed
        else
          Logger.warning(
            "[Notifications] push image URL too long from_user=#{from_user_id} length=#{String.length(trimmed)}"
          )

          nil
        end

      true ->
        Logger.info("[Notifications] push image using proxy URL from_user=#{from_user_id}")
        avatar_proxy_url(from_user_id)
    end
  end

  defp normalize_push_image(_value, from_user_id) do
    Logger.info(
      "[Notifications] push image non-binary value, using proxy URL from_user=#{from_user_id}"
    )

    avatar_proxy_url(from_user_id)
  end

  defp avatar_proxy_url(user_id) when is_binary(user_id) and user_id != "" do
    with base_url when is_binary(base_url) <- sanitized_endpoint_url(),
         true <- base_url != "" do
      encoded_user_id = URI.encode_www_form(user_id)
      "#{base_url}/api/push/avatar/#{encoded_user_id}"
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp avatar_proxy_url(_), do: nil

  defp sanitized_endpoint_url do
    VibeWeb.Endpoint.url()
    |> to_string()
    |> String.trim()
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
    |> String.replace(~r/\[(https?:\/\/)/i, "\\1")
    |> String.replace(~r/\](?=\/|$)/, "")
    |> String.replace(~r/^(https?:\/\/)+/i, fn prefix ->
      case Regex.run(~r/https?:\/\//i, prefix) do
        [single | _] -> String.downcase(single)
        _ -> "https://"
      end
    end)
    |> String.trim_trailing("/")
  end
end
