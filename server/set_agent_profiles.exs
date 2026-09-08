defmodule SetAgentProfiles do
  @claude_image "/Users/mohammadshayani/Vibe/claude_full_orange_bg_4k.png"
  @gpt_image "/Users/mohammadshayani/Vibe/gbp.png"
  @grok_image "/Users/mohammadshayani/Vibe/grok_profile.png"
  @agy_image "/Users/mohammadshayani/Vibe/agy_profile.png"

  def run do
    upload_and_set("claude", @claude_image, "agent-profiles/claude.png")
    upload_and_set("codex", @gpt_image, "agent-profiles/codex.png")
    upload_and_set("grok", @grok_image, "agent-profiles/grok-v2.png")
    upload_and_set("agy", @agy_image, "agent-profiles/agy-v3.png")
  end

  def run_grok_only do
    upload_and_set("grok", @grok_image, "agent-profiles/grok-v2.png")
  end

  def run_agy_only do
    upload_and_set("agy", @agy_image, "agent-profiles/agy-v3.png")
  end

  defp upload_and_set(username, local_path, remote_path) do
    IO.puts("\n=== #{username} ===")

    unless File.exists?(local_path) do
      IO.puts("ERROR: file not found: #{local_path}")
      exit(:file_not_found)
    end

    IO.puts("Uploading #{local_path} -> #{remote_path} ...")

    case Vibe.SupabaseStorage.upload(local_path, remote_path, bucket: "chat-media") do
      {:ok, public_url} ->
        IO.puts("Uploaded: #{public_url}")
        set_profile_image(username, public_url)

      {:error, reason} ->
        IO.puts("Upload failed: #{inspect(reason)}")
        exit(:upload_failed)
    end
  end

  defp set_profile_image(username, url) do
    sql = "UPDATE users SET profile_image = $1, updated_at = NOW() WHERE LOWER(username) = $2"
    case Vibe.Repo.query(sql, [url, String.downcase(username)]) do
      {:ok, %{num_rows: 0}} ->
        IO.puts("ERROR: user '#{username}' not found in DB (0 rows updated)")
        exit(:user_not_found)

      {:ok, %{num_rows: n}} ->
        IO.puts("profile_image set for @#{username} (#{n} row updated)")

      {:error, reason} ->
        IO.puts("DB update failed: #{inspect(reason)}")
        exit(:db_update_failed)
    end
  end
end

# railway run SET_AGENT_ONLY=agy mix run set_agent_profiles.exs (same env.
case System.get_env("SET_AGENT_ONLY") do
  "agy" -> SetAgentProfiles.run_agy_only()
  "grok" -> SetAgentProfiles.run_grok_only()
  _ -> SetAgentProfiles.run()
end

IO.puts("\nDone.")
