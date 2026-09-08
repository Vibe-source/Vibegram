defmodule VibeAgents.Tools.Computer do
  @moduledoc "computer_run / read / write / edit / list files, via VibeAgents.Sandbox."
  alias VibeAgents.Runs.Events
  alias VibeAgents.Sandbox
  alias VibeAgents.Sandbox.Client

  @max_timeout_ms 240_000
  @max_output_chars 16_000

  def computer_run(run, %{"command" => command} = input) when is_binary(command) do
    if String.trim(command) == "" do
      %{"ok" => false, "error" => "command is required"}
    else
      with {:ok, sandbox_id} <- ensure(run) do
        emit_shell_state(run, command)

        body = %{
          "cmd" => ["bash", "-lc", command],
          "cwd" => input["cwd"],
          "timeoutMs" => timeout_ms(input),
          "maxOutputBytes" => @max_output_chars * 4
        }

        case Client.exec(sandbox_id, body) do
          {:ok, result} ->
            %{
              "ok" => true,
              "exitCode" => result["exitCode"],
              "stdout" => truncate(result["stdout"]),
              "stderr" => truncate(result["stderr"]),
              "truncated" => result["truncated"] || false,
              "durationMs" => result["durationMs"]
            }

          {:error, reason} ->
            %{"ok" => false, "error" => "computer_run failed: #{inspect(reason)}"}
        end
      else
        {:error, reason} -> error_result(reason)
      end
    end
  end

  def computer_run(_run, _input), do: %{"ok" => false, "error" => "command is required"}

  defp emit_shell_state(run, command) do
    label = command |> String.split("\n") |> List.first() |> String.slice(0, 80)
    Events.emit(run, "run.computer.state", %{"url" => "", "title" => "$ " <> label, "live" => true})
  end

  def computer_read_file(run, %{"path" => path}) when is_binary(path) do
    with {:ok, sandbox_id} <- ensure(run) do
      case Client.read_file(sandbox_id, path) do
        {:ok, %{"contentBase64" => content} = result} -> %{"ok" => true, "path" => path, "contentBase64" => content, "bytes" => result["bytes"]}
        {:error, reason} -> %{"ok" => false, "error" => "could not read #{path}: #{inspect(reason)}"}
      end
    else
      {:error, reason} -> error_result(reason)
    end
  end

  def computer_read_file(_run, _input), do: %{"ok" => false, "error" => "path is required"}

  def computer_write_file(run, %{"path" => path, "content" => content}) when is_binary(path) and is_binary(content) do
    with {:ok, sandbox_id} <- ensure(run) do
      case Client.write_file(sandbox_id, %{"path" => path, "contentBase64" => Base.encode64(content)}) do
        {:ok, result} -> %{"ok" => true, "path" => path, "bytes" => result["bytes"]}
        {:error, reason} -> %{"ok" => false, "error" => "could not write #{path}: #{inspect(reason)}"}
      end
    else
      {:error, reason} -> error_result(reason)
    end
  end

  def computer_write_file(_run, _input), do: %{"ok" => false, "error" => "path and content are required"}

  def computer_edit_file(run, %{"path" => path, "old" => old, "new" => new} = input)
      when is_binary(path) and is_binary(old) and is_binary(new) do
    replace_all? = input["replace_all"] == true

    with {:ok, sandbox_id} <- ensure(run),
         {:ok, text} <- read_text(sandbox_id, path),
         {:ok, edited, count} <- apply_replacement(text, old, new, replace_all?),
         {:ok, result} <- Client.write_file(sandbox_id, %{"path" => path, "contentBase64" => Base.encode64(edited)}) do
      %{"ok" => true, "path" => path, "replacements" => count, "bytes" => result["bytes"]}
    else
      {:error, :not_found} ->
        %{"ok" => false, "error" => "`old` was not found in #{path}. Read the file first and match it exactly."}

      {:error, {:ambiguous, count}} ->
        %{"ok" => false, "error" => "`old` appears #{count} times in #{path}. Include more surrounding text, or set replace_all."}

      {:error, reason} ->
        error_result(reason)
    end
  end

  def computer_edit_file(_run, _input), do: %{"ok" => false, "error" => "path, old and new are required"}

  def computer_list_files(run, input) do
    path = if is_binary(input["path"]), do: input["path"], else: "."
    depth = if is_integer(input["depth"]) and input["depth"] > 0, do: min(input["depth"], 4), else: 2

    with {:ok, sandbox_id} <- ensure(run) do
      case Client.tree(sandbox_id, path, depth) do
        {:ok, result} -> %{"ok" => true, "path" => path, "entries" => result["entries"] || result["tree"] || []}
        {:error, reason} -> %{"ok" => false, "error" => "could not list #{path}: #{inspect(reason)}"}
      end
    else
      {:error, reason} -> error_result(reason)
    end
  end

  defp read_text(sandbox_id, path) do
    case Client.read_file(sandbox_id, path) do
      {:ok, %{"contentBase64" => content}} ->
        case Base.decode64(content) do
          {:ok, text} -> {:ok, text}
          :error -> {:error, "#{path} is not valid base64"}
        end

      {:error, reason} ->
        {:error, "could not read #{path}: #{inspect(reason)}"}
    end
  end

  defp apply_replacement(text, old, new, replace_all?) do
    case {length(String.split(text, old)) - 1, replace_all?} do
      {0, _} -> {:error, :not_found}
      {count, false} when count > 1 -> {:error, {:ambiguous, count}}
      {count, true} -> {:ok, String.replace(text, old, new), count}
      {1, false} -> {:ok, String.replace(text, old, new, global: false), 1}
    end
  end

  defp ensure(run) do
    case Sandbox.ensure_computer(run.agent_id, run.capabilities || %{}) do
      {:ok, %{sandbox_id: sandbox_id}} when is_binary(sandbox_id) -> {:ok, sandbox_id}
      {:ok, _computer} -> {:error, "sandbox has no id yet"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp timeout_ms(input) do
    case input["timeoutMs"] do
      value when is_integer(value) and value > 0 -> min(value, @max_timeout_ms)
      _ -> 60_000
    end
  end

  defp truncate(text) when is_binary(text) do
    if String.length(text) > @max_output_chars, do: String.slice(text, 0, @max_output_chars) <> "\n... [truncated]", else: text
  end

  defp truncate(_text), do: ""

  defp error_result(:not_configured) do
    %{"ok" => false, "error" => "The computer is not available (sandbox gateway not configured)."}
  end

  defp error_result(reason), do: %{"ok" => false, "error" => "computer unavailable: #{Sandbox.describe_error(reason)}"}
end
