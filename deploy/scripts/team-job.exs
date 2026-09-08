# Hands the Vibe agent team a real job and prints what they did.
#
#   cd server && VIBE_LOCAL_AGENT_WORKERS=1 \
#     VIBE_TEAM_JOB_FILE=/tmp/job.md mix run ../deploy/scripts/team-job.exs
#
# Unlike team-drill.exs this is not a fake crash — the text you pass is the brief,
# and the workers run the real CLIs against the real checkout.
#
#   VIBE_TEAM_JOB / VIBE_TEAM_JOB_FILE   the brief (file wins)
#   VIBE_TEAM_JOB_TO                     who gets it first        (default boss)
#   VIBE_TEAM_JOB_MEMBERS                who is in the room       (default boss,monitor,coder)
#   VIBE_TEAM_JOB_CHAT                   reuse a chat instead of creating one
#   VIBE_TEAM_JOB_TITLE                  group name for a new chat
#   VIBE_TEAM_JOB_QUIET_MS               settle when nothing new arrives (default 120000)
#   VIBE_TEAM_JOB_MAX_MS                 hard stop                (default 1800000)
#   VIBE_TEAM_JOB_OUT                    also write the transcript here

import Ecto.Query

alias Vibe.AI.LocalAgentWorker, as: W
alias Vibe.Repo

owner_username = System.get_env("VIBE_TEAM_OWNER") || "vibegram"

brief =
  case System.get_env("VIBE_TEAM_JOB_FILE") do
    nil -> System.get_env("VIBE_TEAM_JOB")
    path -> File.read!(path)
  end

if brief in [nil, ""] do
  IO.puts("no brief — set VIBE_TEAM_JOB or VIBE_TEAM_JOB_FILE")
  System.halt(2)
end

to = System.get_env("VIBE_TEAM_JOB_TO") || "boss"

members =
  (System.get_env("VIBE_TEAM_JOB_MEMBERS") || "boss,monitor,coder")
  |> String.split(",", trim: true)
  |> Enum.map(&String.trim/1)

quiet_ms = String.to_integer(System.get_env("VIBE_TEAM_JOB_QUIET_MS") || "120000")
max_ms = String.to_integer(System.get_env("VIBE_TEAM_JOB_MAX_MS") || "1800000")

# ── seed ──────────────────────────────────────────────────────────────────────
:ok = W.ensure_agent_users()

owner =
  case Repo.one(from u in "users", where: u.username == ^owner_username, select: %{id: type(u.id, Ecto.UUID)}) do
    nil ->
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      id = Ecto.UUID.generate()

      Repo.insert_all("users", [
        %{
          id: Ecto.UUID.dump!(id),
          username: owner_username,
          name: "Vibegram",
          password_hash: "seed",
          public_key: "seed",
          device_id: "seed",
          is_agent: false,
          tier: "gold",
          inserted_at: now,
          updated_at: now
        }
      ])

      IO.puts("seeded owner #{owner_username}")
      %{id: id}

    found ->
      found
  end

System.put_env("VIBE_AGENT_WORKER_ALLOWED_USERS", owner.id)

System.get_env("VIBE_TEAM_WORKSPACE") ||
  System.put_env("VIBE_TEAM_WORKSPACE", Path.expand("../..", __DIR__))

worker = W.resolve_handle(to) || raise "unknown handle #{to}"

chat_id =
  case System.get_env("VIBE_TEAM_JOB_CHAT") do
    nil ->
      ids = Enum.map(members, fn h -> W.resolve_handle(h).agent_user_id end)
      title = System.get_env("VIBE_TEAM_JOB_TITLE") || "DevOps #{System.system_time(:second)}"
      {:ok, room} = Vibe.Chat.create_group(owner.id, title, ids, nil, "Vibe team")
      room.id

    existing ->
      existing
  end

read_rows = fn ->
  Repo.all(
    from m in "messages",
      join: u in "users",
      on: u.id == m.from_id,
      where: m.chat_id == ^chat_id,
      order_by: [asc: m.inserted_at],
      select: %{author: u.username, body: m.encrypted_content, meta: m.metadata}
  )
end

before = length(read_rows.())

IO.puts("""

  owner    #{owner_username}
  chat     #{chat_id}
  to       @#{worker.handle} (#{W.executor_for(worker)}#{if worker[:model], do: "/" <> worker.model, else: ""})
  room     #{Enum.map_join(members, ", ", &("@" <> &1))}

running the real CLIs — this takes minutes, not seconds…
""")

# ── run ───────────────────────────────────────────────────────────────────────
started_at = System.monotonic_time(:millisecond)

W.handle_chat_message(worker, chat_id, brief,
  requester_user_id: owner.id,
  progress_callback: fn
    %{"label" => label} -> IO.puts("  · #{label}")
    _ -> :ok
  end
)

# Handoffs run under the task supervisor, so settle on quiet rather than a fixed sleep.
settle = fn settle, count, last_change ->
  now = System.monotonic_time(:millisecond)

  cond do
    now - started_at > max_ms ->
      IO.puts("\n(hard stop at #{div(max_ms, 1000)}s)")

    now - last_change > quiet_ms ->
      :ok

    true ->
      Process.sleep(5_000)
      fresh = length(read_rows.())

      if fresh != count do
        IO.puts("  · #{fresh} messages")
        settle.(settle, fresh, now)
      else
        settle.(settle, count, last_change)
      end
  end
end

settle.(settle, before, System.monotonic_time(:millisecond))

# ── read back ─────────────────────────────────────────────────────────────────
rows =
  read_rows.()
  |> Enum.map(&%{&1 | body: Vibe.Chat.AgentMessageCrypto.decrypt_from_storage(&1.body || "")})

elapsed = System.monotonic_time(:millisecond) - started_at

transcript =
  [
    "─── #{chat_id} · #{length(rows)} messages · #{div(elapsed, 1000)}s ───\n",
    Enum.map(rows, fn r ->
      cli = (r.meta || %{})["agentWorkerCommand"]
      "@#{r.author}#{if cli, do: " (#{cli})", else: ""}:\n#{r.body}\n"
    end)
  ]
  |> IO.iodata_to_binary()

IO.puts("\n" <> transcript)

case System.get_env("VIBE_TEAM_JOB_OUT") do
  nil -> :ok
  path -> File.write!(path, transcript)
end

IO.puts("authors: #{rows |> Enum.map(& &1.author) |> Enum.uniq() |> Enum.join(", ")}")
IO.puts("chat: #{chat_id}")
