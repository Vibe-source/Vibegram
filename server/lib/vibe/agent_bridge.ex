defmodule Vibe.AgentBridge do
  @moduledoc """
  Pairing + token management for the **agent bridge**.
  """

  require Logger
  import Ecto.Query
  alias Vibe.Repo
  alias Vibe.AgentBridge.Connection

  @pairing_table :agent_bridge_pairings
  @request_table :agent_bridge_requests
  @pending_ask_table :agent_bridge_pending_asks
  @pending_task_table :agent_bridge_pending_tasks
  @pairing_ttl_ms 10 * 60 * 1000
  @request_ttl_ms 10 * 60 * 1000
  @pending_task_ttl_ms 30 * 60 * 1000

  # ── Scan-to-pair (daemon-initiated; the phone scans the desktop QR) ──

  @doc """
  Create a pairing request initiated by the daemon (desktop).
  """
  def create_request(device_label \\ "computer") do
    ensure_table(@request_table)
    request_id = generate_token(18)
    device_secret = generate_token(24)
    expires_at = System.system_time(:millisecond) + @request_ttl_ms

    :ets.insert(
      @request_table,
      {request_id,
       %{
         device_hash: hash_token(device_secret),
         device_label: normalize(device_label) || "computer",
         status: :pending,
         user_id: nil,
         bridge_token: nil,
         expires_at: expires_at
       }}
    )

    %{
      request_id: request_id,
      device_secret: device_secret,
      expires_in: div(@request_ttl_ms, 1000)
    }
  end

  @doc """
  Authorize a pending request for `user_id` — called by the authenticated phone right after it
  scans the QR.
  """
  def authorize_request(request_id, user_id)
      when is_binary(request_id) and is_binary(user_id) and user_id != "" do
    ensure_table(@request_table)
    now = System.system_time(:millisecond)

    case :ets.lookup(@request_table, request_id) do
      [{^request_id, %{status: :pending, expires_at: exp} = req}] when exp > now ->
        case mint_token(user_id, req.device_label) do
          {:ok, %{bridge_token: token, computer_id: computer_id, device_label: device_label}} ->
            :ets.insert(
              @request_table,
              {request_id,
               req
               |> Map.put(:status, :authorized)
               |> Map.put(:user_id, user_id)
               |> Map.put(:bridge_token, token)
               |> Map.put(:computer_id, computer_id)
               |> Map.put(:device_label, device_label)}
            )

            :ok

          {:error, _} = err ->
            err
        end

      [{^request_id, %{status: :authorized}}] ->
        {:error, :already_authorized}

      [{^request_id, _expired}] ->
        :ets.delete(@request_table, request_id)
        {:error, :expired}

      _ ->
        {:error, :invalid_request}
    end
  end

  def authorize_request(_, _), do: {:error, :invalid_request}

  @doc """
  Claim the parked bridge token for an authorized request — called by the daemon,
  proving ownership with its `device_secret`. Single use.
  """
  def claim_request(request_id, device_secret)
      when is_binary(request_id) and is_binary(device_secret) do
    ensure_table(@request_table)
    now = System.system_time(:millisecond)

    case :ets.lookup(@request_table, request_id) do
      [{^request_id, %{expires_at: exp}}] when exp <= now ->
        :ets.delete(@request_table, request_id)
        {:error, :expired}

      [{^request_id,
        %{
          status: :authorized,
          device_hash: dh,
          user_id: uid,
          bridge_token: token,
          computer_id: computer_id
        }}] ->
        if Plug.Crypto.secure_compare(hash_token(device_secret), dh) do
          :ets.delete(@request_table, request_id)
          {:ok, %{user_id: uid, bridge_token: token, computer_id: computer_id}}
        else
          {:error, :invalid}
        end

      [{^request_id, %{status: :pending}}] ->
        {:error, :pending}

      _ ->
        {:error, :invalid_request}
    end
  end

  def claim_request(_, _), do: {:error, :invalid_request}


  @doc """
  Remember the latest unanswered ask for `chat_id` so it can be replayed to a phone that joins
  `chat:<id>` after missing the live broadcast.
  """
  def remember_pending_ask(chat_id, request_id, payload)
      when is_binary(chat_id) and chat_id != "" and is_binary(request_id) and is_map(payload) do
    ensure_table(@pending_ask_table)
    :ets.insert(
      @pending_ask_table,
      {chat_id, %{request_id: request_id, payload: payload}}
    )

    :ok
  end

  def remember_pending_ask(_, _, _), do: :ok

  @doc """
  Peek the buffered ask payload for `chat_id` (or `nil` if none).
  Does not consume it — a still-unanswered ask must survive repeated rejoins.
  """
  def pending_ask(chat_id) when is_binary(chat_id) and chat_id != "" do
    ensure_table(@pending_ask_table)
    case :ets.lookup(@pending_ask_table, chat_id) do
      [{^chat_id, %{payload: payload}}] ->
        payload

      _ ->
        nil
    end
  end

  def pending_ask(_), do: nil

  @doc """
  Clear the buffered ask for `chat_id` once it has been answered.
  """
  def clear_pending_ask(chat_id, request_id) when is_binary(chat_id) and chat_id != "" do
    ensure_table(@pending_ask_table)

    case :ets.lookup(@pending_ask_table, chat_id) do
      [{^chat_id, %{request_id: ^request_id}}] ->
        :ets.delete(@pending_ask_table, chat_id)

      [{^chat_id, _}] when is_nil(request_id) ->
        :ets.delete(@pending_ask_table, chat_id)

      _ ->
        :ok
    end

    :ok
  end

  def clear_pending_ask(_, _), do: :ok


  @doc """
  Mint a single-use pairing code for `user_id`. Returns the code and its TTL; the
  app composes the QR / install command from its known server URL.
  """
  def request_pairing(user_id) when is_binary(user_id) and user_id != "" do
    ensure_table(@pairing_table)
    code = generate_pairing_code()
    expires_at = System.system_time(:millisecond) + @pairing_ttl_ms
    :ets.insert(@pairing_table, {code, %{user_id: user_id, expires_at: expires_at}})

    %{pairing_code: code, expires_in: div(@pairing_ttl_ms, 1000)}
  end

  @doc """
  Redeem a pairing code (called by the daemon). Consumes the code (single use) and
  mints a long-lived bridge token bound to the code's user.
  """
  def redeem_pairing(code, device_label \\ "computer") when is_binary(code) do
    ensure_table(@pairing_table)
    now = System.system_time(:millisecond)

    case :ets.lookup(@pairing_table, code) do
      [{^code, %{user_id: user_id, expires_at: expires_at}}] when expires_at > now ->
        :ets.delete(@pairing_table, code)
        mint_token(user_id, device_label)

      [{^code, _expired}] ->
        :ets.delete(@pairing_table, code)
        {:error, :expired}

      _ ->
        {:error, :invalid_code}
    end
  end


  defp mint_token(user_id, device_label) do
    raw = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %Connection{}
    |> Connection.changeset(%{
      user_id: user_id,
      token_hash: hash_token(raw),
      device_label: normalize(device_label) || "computer",
      last_seen_at: now
    })
    |> Repo.insert()
    |> case do
      {:ok, connection} ->
        {:ok,
         %{
           user_id: user_id,
           bridge_token: raw,
           computer_id: to_string(connection.id),
           device_label: connection.device_label
         }}

      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc "Resolve a bridge token to its user id, or `:error`. Updates last_seen_at."
  def verify_token(token) when is_binary(token) and token != "" do
    case verify_connection(token) do
      {:ok, %{user_id: user_id}} -> {:ok, user_id}
      _ -> :error
    end
  end

  def verify_token(_), do: :error

  @doc "Resolve a bridge token to its user and stable paired-computer identity."
  def verify_connection(token) when is_binary(token) and token != "" do
    hash = hash_token(token)

    case Repo.one(from(c in Connection, where: c.token_hash == ^hash and is_nil(c.revoked_at))) do
      %Connection{} = connection ->
        touch(connection)
        {:ok,
         %{
           user_id: to_string(connection.user_id),
           computer_id: to_string(connection.id),
           device_label: connection.device_label || "computer"
         }}

      _ ->
        :error
    end
  end

  def verify_connection(_), do: :error

  @doc "Revoke all active bridge tokens for a user (\"disconnect computer\")."
  def revoke_all(user_id) when is_binary(user_id) and user_id != "" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      Repo.update_all(
        from(c in Connection, where: c.user_id == ^user_id and is_nil(c.revoked_at)),
        set: [revoked_at: now, updated_at: now]
      )

    {:ok, count}
  end

  def revoke_all(_), do: {:ok, 0}

  @doc "Whether the user has any non-revoked paired computer on record."
  def paired?(user_id) when is_binary(user_id) do
    Repo.exists?(from(c in Connection, where: c.user_id == ^user_id and is_nil(c.revoked_at)))
  rescue
    _ -> false
  end

  def paired?(_), do: false

  defp touch(%Connection{} = connection) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    connection
    |> Ecto.Changeset.change(last_seen_at: now)
    |> Repo.update()
  rescue
    _ -> :ok
  end


  @doc "Is a paired computer connected to the bridge channel right now?"
  def online?(user_id) when is_binary(user_id) and user_id != "" do
    map_size(VibeWeb.Presence.list("bridge:#{user_id}")) > 0
  rescue
    _ -> false
  end

  def online?(_), do: false

  @doc """
  Status payload for a live push to the phone, built without a DB round trip whenever possible.
  """
  def status_for_push(user_id) when is_binary(user_id) and user_id != "" do
    if online?(user_id) do
      presence_status(user_id, true)
    else
      presence_status(user_id, paired?(user_id))
    end
  rescue
    _ -> status(user_id)
  end

  def status_for_push(_user_id), do: status(nil)

  @doc "Public bridge status for the phone UI, including connected devices and repo choices."
  def status(user_id) when is_binary(user_id) and user_id != "" do
    presence_status(user_id, paired?(user_id))
  rescue
    _ ->
      %{
        connected: false,
        paired: paired?(user_id),
        devices: [],
        repositories: [],
        runningTasks: [],
        models: %{}
      }
  end

  def status(_),
    do: %{
      connected: false,
      paired: false,
      devices: [],
      repositories: [],
      runningTasks: [],
      models: %{}
    }

  defp presence_status(user_id, paired) do
    presence = VibeWeb.Presence.list(topic(user_id))
    devices = presence_devices(presence)

    repositories =
      devices
      |> Enum.flat_map(fn device -> Map.get(device, "repositories", []) end)
      |> dedupe_repositories()

    running_tasks =
      devices
      |> Enum.flat_map(fn device -> Map.get(device, "runningTasks", []) end)
      |> dedupe_running_tasks()

    models =
      devices
      |> Enum.map(fn device -> Map.get(device, "models") end)
      |> Enum.find(&is_map/1)

    %{
      connected: map_size(presence) > 0,
      paired: paired,
      devices: devices,
      repositories: repositories,
      runningTasks: running_tasks,
      models: models || %{}
    }
  end

  @doc "Normalize daemon-reported status before storing it in Presence metadata."
  def presence_meta(payload, computer_id \\ nil)

  def presence_meta(payload, computer_id) when is_map(payload) do
    computer_id = normalize(computer_id || payload["computerId"] || payload["computer_id"])

    %{
      "online_at" => System.system_time(:second),
      "id" => computer_id,
      "computerId" => computer_id,
      "deviceLabel" => normalize(payload["deviceLabel"] || payload["device_label"]) || "computer",
      "cwd" => normalize(payload["cwd"]),
      "repositories" =>
        payload["repositories"]
        |> normalize_repositories()
        |> attach_computer_identity(computer_id, payload["deviceLabel"] || payload["device_label"]),
      "runningTasks" =>
        (payload["runningTasks"] || payload["running_tasks"])
        |> normalize_running_tasks()
        |> attach_computer_identity(computer_id, payload["deviceLabel"] || payload["device_label"]),
      "permissions" => normalize_permissions(payload["permissions"]),
      "models" => normalize_provider_models(payload["models"])
    }
  end

  def presence_meta(_payload, _computer_id) do
    %{"online_at" => System.system_time(:second), "repositories" => []}
  end

  @doc "The bridge channel topic for a user."
  def topic(user_id), do: "bridge:#{user_id}"

  @doc """
  Push a task to a user's connected bridge daemon.
  """
  def dispatch_task(user_id, payload) when is_binary(user_id) and is_map(payload) do
    case dispatch_to_computer(user_id, "run_task", payload) do
      :ok ->
        :ok

      {:error, reason} = error when reason in [:offline, :computer_offline] ->
        if paired?(user_id), do: queue_pending_task(user_id, payload), else: error

      error ->
        error
    end
  end

  @doc """
  Flush queued run_task payloads eligible for a bridge that just joined.
  """
  def flush_pending_tasks(user_id, computer_id, device_label)
      when is_binary(user_id) and is_binary(computer_id) do
    ensure_table(@pending_task_table)
    now = System.system_time(:millisecond)

    @pending_task_table
    |> :ets.tab2list()
    |> Enum.reduce(0, fn
      {{^user_id, task_id} = key, entry}, count ->
        requested = Map.get(entry, :computer_id)

        cond do
          now - entry.queued_at > @pending_task_ttl_ms ->
            :ets.delete(@pending_task_table, key)
            count

          is_binary(requested) and requested != computer_id ->
            count

          true ->
            case :ets.take(@pending_task_table, key) do
              [{^key, claimed}] ->
                payload =
                  claimed.payload
                  |> Map.put("computerId", computer_id)
                  |> Map.put("computerLabel", normalize(device_label) || "computer")

                VibeWeb.Endpoint.broadcast(topic(user_id), "run_task", payload)

                Logger.info(
                  "[AgentBridge] flushed queued task user=#{user_id} computer=#{computer_id} task=#{task_id}"
                )

                count + 1

              _ ->
                count
            end
        end

      {_other_key, _entry}, count ->
        count
    end)
  rescue
    error ->
      Logger.warning(
        "[AgentBridge] pending task flush failed user=#{user_id}: #{Exception.message(error)}"
      )

      0
  end

  def flush_pending_tasks(_, _, _), do: 0

  @doc """
  Push a control action to the connected bridge daemon for an in-flight task.
  """
  def dispatch_control(user_id, payload) when is_binary(user_id) and is_map(payload) do
    dispatch_to_computer(user_id, "control_task", payload)
  end

  @doc """
  Ask a user's connected bridge daemon for the agent's local conversation history (Claude Code
  / Codex session logs).
  """
  def dispatch_history(user_id, payload) when is_binary(user_id) and is_map(payload) do
    dispatch_to_computer(user_id, "history_request", payload)
  end

  @doc """
  Ask a user's connected bridge daemon for the full contents of a file the agent touched.
  """
  def dispatch_file(user_id, payload) when is_binary(user_id) and is_map(payload) do
    dispatch_to_computer(user_id, "file_request", payload)
  end

  @doc """
  Ask a user's connected bridge daemon for a structured usage snapshot (Claude subscription
  5h/7-day limits + this chat's last-run tokens).
  """
  def dispatch_usage(user_id, payload) when is_binary(user_id) and is_map(payload) do
    dispatch_to_computer(user_id, "usage_request", payload)
  end

  @doc """
  Relay the phone's answer to a bridge-issued `ask_request` (plan approval or a mid-run
  question) back to the user's connected bridge daemon.
  """
  def dispatch_ask_response(user_id, payload) when is_binary(user_id) and is_map(payload) do
    dispatch_to_computer(user_id, "ask_response", payload)
  end


  defp hash_token(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

  defp generate_pairing_code do
    :crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false)
  end

  defp generate_token(bytes) do
    :crypto.strong_rand_bytes(bytes) |> Base.url_encode64(padding: false)
  end

  defp ensure_table(table) do
    case :ets.whereis(table) do
      :undefined ->
        :ets.new(table, [:set, :public, :named_table, {:read_concurrency, true}])
        :ok

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp normalize(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize(_), do: nil

  defp presence_devices(presence) when is_map(presence) do
    presence
    |> Enum.flat_map(fn {_key, %{metas: metas}} -> metas || [] end)
    |> Enum.map(&public_presence_meta/1)
  end

  defp presence_devices(_), do: []

  defp public_presence_meta(meta) when is_map(meta) do
    computer_id = normalize(meta["computerId"] || meta[:computerId] || meta["id"] || meta[:id])
    device_label =
      meta["deviceLabel"] || meta[:deviceLabel] || meta["device_label"] || "computer"

    %{
      "id" => computer_id,
      "computerId" => computer_id,
      "online_at" => meta["online_at"] || meta[:online_at],
      "deviceLabel" => device_label,
      "cwd" => meta["cwd"] || meta[:cwd],
      "repositories" =>
        (meta["repositories"] || meta[:repositories])
        |> normalize_repositories()
        |> attach_computer_identity(computer_id, device_label),
      "runningTasks" =>
        (meta["runningTasks"] || meta[:runningTasks] || meta["running_tasks"])
        |> normalize_running_tasks()
        |> attach_computer_identity(computer_id, device_label),
      "permissions" => normalize_permissions(meta["permissions"] || meta[:permissions]),
      "models" => normalize_provider_models(meta["models"] || meta[:models])
    }
  end

  defp public_presence_meta(_), do: %{"repositories" => []}

  defp normalize_provider_models(models) when is_map(models) do
    models
    |> Enum.reduce(%{}, fn {provider, rows}, acc ->
      key = provider |> to_string() |> String.downcase()

      list =
        rows
        |> List.wrap()
        |> Enum.map(&normalize_model_choice/1)
        |> Enum.reject(&is_nil/1)

      if list == [], do: acc, else: Map.put(acc, key, list)
    end)
  end

  defp normalize_provider_models(_), do: %{}

  defp normalize_model_choice(row) when is_map(row) do
    id = normalize(row["id"] || row[:id] || row["value"] || row[:value])
    title = normalize(row["title"] || row[:title] || row["name"] || row[:name] || id)
    if is_nil(id) or is_nil(title) do
      nil
    else
      %{
        "id" => id,
        "title" => title,
        "subtitle" => normalize(row["subtitle"] || row[:subtitle]),
        "isDefault" =>
          row["isDefault"] == true || row[:isDefault] == true || row["is_default"] == true,
        "apiId" => normalize(row["apiId"] || row[:apiId] || row["api_id"]),
        "efforts" => normalize_effort_levels(row["efforts"] || row[:efforts]),
        "defaultEffort" =>
          normalize(row["defaultEffort"] || row[:defaultEffort] || row["default_effort"]),
        "source" => normalize(row["source"] || row[:source])
      }
    end
  end

  defp normalize_model_choice(_), do: nil

  defp normalize_effort_levels(levels) when is_list(levels) do
    levels
    |> Enum.map(&normalize/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_effort_levels(_), do: []

  defp normalize_repositories(values) when is_list(values) do
    values
    |> Enum.map(&normalize_repository/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_repositories(_), do: []

  defp normalize_running_tasks(values) when is_list(values) do
    values
    |> Enum.map(&normalize_running_task/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_running_tasks(_), do: []

  defp normalize_running_task(task) when is_map(task) do
    task_id = normalize(task["taskId"] || task[:taskId] || task["task_id"] || task[:task_id])

    if is_nil(task_id) do
      nil
    else
      %{
        "provider" => normalize(task["provider"] || task[:provider]),
        "chatId" =>
          normalize(task["chatId"] || task[:chatId] || task["chat_id"] || task[:chat_id]),
        "taskId" => task_id,
        "sessionId" =>
          normalize(
            task["sessionId"] || task[:sessionId] || task["session_id"] || task[:session_id]
          ),
        "topic" => normalize(task["topic"] || task[:topic]) || "Running task",
        "repoId" =>
          normalize(task["repoId"] || task[:repoId] || task["repo_id"] || task[:repo_id]),
        "repoName" =>
          normalize(task["repoName"] || task[:repoName] || task["repo_name"] || task[:repo_name]),
        "project" => normalize(task["project"] || task[:project] || task["cwd"] || task[:cwd]),
        "projectName" =>
          normalize(
            task["projectName"] || task[:projectName] || task["project_name"] ||
              task[:project_name]
          ),
        "cwd" => normalize(task["cwd"] || task[:cwd]),
        "workMode" =>
          normalize(task["workMode"] || task[:workMode] || task["work_mode"] || task[:work_mode]),
        "startedAt" =>
          normalize(
            task["startedAt"] || task[:startedAt] || task["started_at"] || task[:started_at]
          ),
        "durationMs" =>
          task["durationMs"] || task[:durationMs] || task["duration_ms"] || task[:duration_ms],
        "command" => normalize(task["command"] || task[:command]),
        "pendingCommand" =>
          normalize(
            task["pendingCommand"] || task[:pendingCommand] || task["pending_command"] ||
              task[:pending_command]
          ),
        "teamMode" =>
          normalize(task["teamMode"] || task[:teamMode] || task["team_mode"] || task[:team_mode]),
        "teamRunId" =>
          normalize(
            task["teamRunId"] || task[:teamRunId] || task["team_run_id"] || task[:team_run_id]
          ),
        "teamWorker" =>
          normalize(
            task["teamWorker"] || task[:teamWorker] || task["team_worker"] ||
              task[:team_worker]
          ),
        "teamWorkers" =>
          normalize_string_list(
            task["teamWorkers"] || task[:teamWorkers] || task["team_workers"] ||
              task[:team_workers]
          ),
        "leadWorker" =>
          normalize(
            task["leadWorker"] || task[:leadWorker] || task["lead_worker"] || task[:lead_worker]
          ),
        "teamRole" =>
          normalize(task["teamRole"] || task[:teamRole] || task["team_role"] || task[:team_role]),
        "suppressVisible" =>
          task["suppressVisible"] == true or task[:suppressVisible] == true or
            task["suppress_visible"] == true or task[:suppress_visible] == true,
        "computerId" =>
          normalize(
            task["computerId"] || task[:computerId] || task["computer_id"] ||
              task[:computer_id]
          ),
        "computerLabel" =>
          normalize(
            task["computerLabel"] || task[:computerLabel] || task["computer_label"] ||
              task[:computer_label]
          )
      }
    end
  end

  defp normalize_running_task(_), do: nil

  defp normalize_string_list(values) when is_list(values) do
    values
    |> Enum.map(&normalize/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_string_list(_), do: []

  defp normalize_repository(repo) when is_map(repo) do
    path = normalize(repo["path"] || repo[:path] || repo["cwd"] || repo[:cwd])
    id = normalize(repo["id"] || repo[:id])

    cond do
      is_nil(path) ->
        nil

      true ->
        %{
          "id" => id || repo_id(path),
          "name" => normalize(repo["name"] || repo[:name]) || Path.basename(path),
          "path" => path,
          "cwd" => normalize(repo["cwd"] || repo[:cwd]) || path,
          "source" => normalize(repo["source"] || repo[:source]) || "bridge",
          "git" => truthy?(repo["git"] || repo[:git]),
          "computerId" =>
            normalize(
              repo["computerId"] || repo[:computerId] || repo["computer_id"] ||
                repo[:computer_id]
            ),
          "computerLabel" =>
            normalize(
              repo["computerLabel"] || repo[:computerLabel] || repo["computer_label"] ||
                repo[:computer_label]
            )
        }
    end
  end

  defp normalize_repository(_), do: nil

  defp repo_id(path) do
    :crypto.hash(:sha256, path)
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 16)
  end

  defp dedupe_repositories(repositories) do
    repositories
    |> Enum.reduce({MapSet.new(), []}, fn repo, {seen, acc} ->
      key = {repo["computerId"], repo["id"] || repo["path"]}

      if elem(key, 1) && not MapSet.member?(seen, key) do
        {MapSet.put(seen, key), [repo | acc]}
      else
        {seen, acc}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp dedupe_running_tasks(tasks) do
    tasks
    |> Enum.reduce({MapSet.new(), []}, fn task, {seen, acc} ->
      key = task["taskId"] || task["sessionId"]

      if is_binary(key) and not MapSet.member?(seen, key) do
        {MapSet.put(seen, key), [task | acc]}
      else
        {seen, acc}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp normalize_permissions(value) when is_map(value), do: value
  defp normalize_permissions(_), do: %{}

  defp attach_computer_identity(items, computer_id, device_label) when is_list(items) do
    label = normalize(device_label) || "computer"

    Enum.map(items, fn item ->
      item
      |> Map.put("computerId", computer_id)
      |> Map.put("computerLabel", label)
    end)
  end

  defp attach_computer_identity(items, _computer_id, _device_label), do: items

  defp dispatch_to_computer(user_id, event, payload) do
    devices = status(user_id).devices
    requested =
      normalize(
        payload["computerId"] || payload["computer_id"] || payload["agentBridgeComputerId"] ||
          payload["agent_bridge_computer_id"]
      )

    selected =
      cond do
        is_binary(requested) -> Enum.find(devices, &(&1["id"] == requested))
        length(devices) == 1 -> hd(devices)
        true -> nil
      end

    cond do
      devices == [] ->
        {:error, :offline}

      is_nil(selected) and is_nil(requested) ->
        {:error, :computer_required}

      is_nil(selected) ->
        {:error, :computer_offline}

      true ->
        computer_id = selected["id"]

        VibeWeb.Endpoint.broadcast(
          topic(user_id),
          event,
          payload
          |> Map.put("computerId", computer_id)
          |> Map.put("computerLabel", selected["deviceLabel"] || "computer")
        )

        :ok
    end
  end

  defp queue_pending_task(user_id, payload) do
    ensure_table(@pending_task_table)
    task_id = normalize(payload["taskId"] || payload["task_id"])

    if is_binary(task_id) do
      key = {user_id, task_id}

      entry = %{
        payload: payload,
        computer_id:
          normalize(
            payload["computerId"] || payload["computer_id"] ||
              payload["agentBridgeComputerId"] || payload["agent_bridge_computer_id"]
          ),
        queued_at: System.system_time(:millisecond)
      }

      inserted? = :ets.insert_new(@pending_task_table, {key, entry})

      Logger.info(
        "[AgentBridge] #{if(inserted?, do: "queued", else: "deduped")} task during reconnect " <>
          "user=#{user_id} task=#{task_id}"
      )

      :ok
    else
      {:error, :offline}
    end
  end

  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_), do: false
end
