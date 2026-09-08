defmodule VibeAgentsWeb.ProviderControllerTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Phoenix.ConnTest

  alias VibeAgents.Repo
  alias VibeAgents.Test.FakeCoreHTTP

  @endpoint VibeAgentsWeb.Endpoint

  setup do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(VibeAgents.Runs.Supervisor), is_pid(pid) do
      DynamicSupervisor.terminate_child(VibeAgents.Runs.Supervisor, pid)
    end

    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    FakeCoreHTTP.reset()
    Application.put_env(:vibe_agents, :kill_switch, false)
    Application.put_env(:vibe_agents, :fake_llm_script, [{:text, "hi"}])
    on_exit(fn -> Application.delete_env(:vibe_agents, :fake_llm_script) end)
    :ok
  end

  defp invoke(conn, identifier, body, headers) do
    conn = Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
    post(conn, "/v1/agents/#{identifier}/invoke", body)
  end

  test "missing secret is 401 and never reaches the core" do
    conn = invoke(build_conn(), "someagent", %{"input" => %{"text" => "hi"}}, [{"content-type", "application/json"}])
    assert json_response(conn, 401)["error"] == "missing_secret"
    assert FakeCoreHTTP.calls_to("/provider-auth") == []
  end

  test "a bad secret is 401" do
    conn = invoke(build_conn(), "someagent", %{"input" => %{"text" => "hi"}}, [{"content-type", "application/json"}, {"x-vibe-agent-secret", "nope"}])
    assert json_response(conn, 401)["error"] == "unauthorized"
  end

  test "a good secret starts a run (202) and replays on the same idempotency key" do
    headers = [{"content-type", "application/json"}, {"x-vibe-agent-secret", "good-secret"}, {"idempotency-key", "k-" <> Ecto.UUID.generate()}]
    body = %{"input" => %{"text" => "hello"}, "chatId" => "chat-1"}

    conn1 = invoke(build_conn(), "someagent", body, headers)
    assert %{"taskId" => task_id, "status" => _} = json_response(conn1, 202)

    conn2 = invoke(build_conn(), "someagent", body, headers)
    assert json_response(conn2, 202)["taskId"] == task_id

    assert length(FakeCoreHTTP.calls_to("/provider-auth")) == 1
  end

  defp start_task(secret) do
    headers = [{"content-type", "application/json"}, {"authorization", "Bearer #{secret}"}]
    conn = invoke(build_conn(), "someagent", %{"input" => %{"text" => "hello"}, "chatId" => "chat-1"}, headers)
    json_response(conn, 202)["taskId"]
  end

  defp read_task(task_id, headers) do
    conn = Enum.reduce(headers, build_conn(), fn {k, v}, acc -> put_req_header(acc, k, v) end)
    get(conn, "/v1/tasks/#{task_id}")
  end

  test "task status is readable with the secret that started it" do
    task_id = start_task("good-secret")
    conn = read_task(task_id, [{"x-vibe-agent-secret", "good-secret"}])
    assert json_response(conn, 200)["taskId"] == task_id
  end

  test "task requires the provider secret" do
    task_id = start_task("good-secret")
    assert json_response(read_task(task_id, []), 401)["error"] == "unauthorized"
  end

  test "task rejects another agents secret" do
    task_id = start_task("good-secret")
    conn = read_task(task_id, [{"x-vibe-agent-secret", "other-secret"}])
    assert json_response(conn, 401)["error"] == "unauthorized"
  end

  test "an unknown task is 404, not a secret oracle" do
    conn = read_task(Ecto.UUID.generate(), [{"x-vibe-agent-secret", "good-secret"}])
    assert conn.status in [401, 404]
  end

  test "public healthz needs no auth; internal healthz does" do
    assert json_response(get(build_conn(), "/healthz"), 200)["ok"] == true
    assert get(build_conn(), "/internal/v1/healthz").status == 401
  end
end
