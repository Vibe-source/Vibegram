# Fake-crash drill for the Vibe agent team.
#
#   cd server && VIBE_LOCAL_AGENT_WORKERS=1 mix run ../deploy/scripts/team-drill.exs
#
# VIBE_TEAM_EXECUTOR=grok runs the whole team on one CLI, for when only that
# subscription is signed in. Roles and routing are unchanged; only the CLI is.
#
# Seeds a group chat containing the owner + @monitor + @coder, hands @monitor a
# fake iOS crash report, and prints every message the team produces. Proves three
# things at once: the role brief reaches the CLI, each agent posts under its OWN
# identity, and a handoff mention actually dispatches the next agent.
#
# Nothing here touches production — it runs against vibe_dev on this machine.

import Ecto.Query

alias Vibe.AI.LocalAgentWorker, as: W
alias Vibe.Repo

require Logger

owner_username = System.get_env("VIBE_TEAM_OWNER") || "vibegram"

crash_report = """
Fake crash report (drill — do not deploy anything, this is a test).

iOS client, VibeLog export, build 2026.9.1:

  FATAL crypto  hybrid open failed  chat=9f2c… epoch=41
    ChatEngine.swift:266  chatEngineDecryptHybridMessage.fail
    reason=mls_open_one_shot  retry=2  plaintextRetained=false
  WARN  crypto  opened but row has nothing to render  ChatEngine.swift:10637
  count=painted 0 of 14 rows in the last 5 minutes

Say in two or three lines what you think broke and who should fix it. If it needs
a code change, hand it to @coder with the file and the reason.
"""

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
          password_hash: "drill",
          public_key: "drill",
          device_id: "drill",
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

# The team only runs for an allowlisted owner — role workers fail closed.
System.put_env("VIBE_AGENT_WORKER_ALLOWED_USERS", owner.id)

# Role workers get the checkout; customer bridge workers keep the empty scratch dir.
System.get_env("VIBE_TEAM_WORKSPACE") ||
  System.put_env("VIBE_TEAM_WORKSPACE", Path.expand("../..", __DIR__))

monitor = W.resolve_handle("monitor")
coder = W.resolve_handle("coder")

{:ok, room} =
  Vibe.Chat.create_group(
    owner.id,
    "DevOps drill #{System.system_time(:second)}",
    [monitor.agent_user_id, coder.agent_user_id],
    nil,
    "Fake crash drill"
  )

chat_id = room.id

IO.puts("""

  owner    #{owner_username} (#{String.slice(owner.id, 0, 8)})
  chat     #{chat_id}
  team     @#{monitor.handle} (#{W.executor_for(monitor)}) · @#{coder.handle} (#{W.executor_for(coder)})

handing the crash report to @monitor — this runs the real CLI, give it a minute…
""")

# ── run ───────────────────────────────────────────────────────────────────────
started_at = System.monotonic_time(:millisecond)

W.handle_chat_message(monitor, chat_id, crash_report,
  requester_user_id: owner.id,
  progress_callback: fn event ->
    case event do
      %{"label" => label} -> IO.puts("  · #{label}")
      _ -> :ok
    end
  end
)

# The handoff to @coder is dispatched under the task supervisor, so give it room
# to finish before reading the transcript back.
Process.sleep(String.to_integer(System.get_env("VIBE_TEAM_DRILL_SETTLE_MS") || "90000"))

# ── read back ─────────────────────────────────────────────────────────────────
rows =
  Repo.all(
    from m in "messages",
      join: u in "users",
      on: u.id == m.from_id,
      where: m.chat_id == ^chat_id,
      order_by: [asc: m.inserted_at],
      select: %{
        author: u.username,
        body: m.encrypted_content,
        meta: m.metadata,
        inserted_at: m.inserted_at
      }
  )
  |> Enum.map(fn r ->
    %{r | body: Vibe.Chat.AgentMessageCrypto.decrypt_from_storage(r.body || "")}
  end)

IO.puts("\n─── transcript (#{length(rows)} messages, #{System.monotonic_time(:millisecond) - started_at}ms) ───\n")

for r <- rows do
  cli = (r.meta || %{})["agentWorkerCommand"]
  IO.puts("@#{r.author}#{if cli, do: " (ran #{cli})", else: ""}:")
  IO.puts(r.body |> to_string() |> String.slice(0, 1400))
  IO.puts("")
end

authors = rows |> Enum.map(& &1.author) |> Enum.uniq()

IO.puts("authors: #{Enum.join(authors, ", ")}")

cond do
  "coder" in authors and "monitor" in authors ->
    IO.puts("PASS — monitor replied and handed off to coder, each under its own identity.")

  "monitor" in authors ->
    IO.puts("PARTIAL — monitor replied but did not hand off to @coder.")

  true ->
    IO.puts("FAIL — monitor did not post. Check VIBE_LOCAL_AGENT_WORKERS=1 and that `claude` is on PATH.")
end
