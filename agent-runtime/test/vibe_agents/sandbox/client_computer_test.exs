defmodule VibeAgents.Sandbox.ClientComputerTest do
  @moduledoc "Real HTTP against a stub gateway: the transport's 204 and 409 mapping."
  use ExUnit.Case, async: false

  alias VibeAgents.Sandbox.Client

  defmodule GatewayStub do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      cond do
        String.ends_with?(conn.request_path, "/computer/frame") and conn.query_string =~ "since=7" ->
          send_resp(conn, 204, "")

        String.ends_with?(conn.request_path, "/computer/frame") ->
          reply(conn, 200, %{"seq" => 8, "imageBase64" => "aGk=", "mime" => "image/jpeg"})

        String.ends_with?(conn.request_path, "/computer/input") ->
          reply(conn, 409, %{"error" => "control_not_held"})

        true ->
          reply(conn, 200, %{"ok" => true})
      end
    end

    defp reply(conn, status, body) do
      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
    end
  end

  setup do
    ref = make_ref()
    {:ok, _pid} = Plug.Cowboy.http(GatewayStub, [], ip: {127, 0, 0, 1}, port: 0, ref: ref)
    port = :ranch.get_port(ref)

    Application.put_env(:vibe_agents, :sandbox_gateway_url, "http://127.0.0.1:#{port}")
    Application.put_env(:vibe_agents, :sandbox_gateway_token, String.duplicate("t", 40))
    Application.put_env(:vibe_agents, :sandbox_http, Client.Finch)

    on_exit(fn ->
      Plug.Cowboy.shutdown(ref)
      Application.delete_env(:vibe_agents, :sandbox_gateway_url)
      Application.delete_env(:vibe_agents, :sandbox_gateway_token)
      Application.put_env(:vibe_agents, :sandbox_http, VibeAgents.Test.FakeSandboxHTTP)
    end)

    :ok
  end

  test "a 204 frame is {:ok, :no_change}, never an error and never an empty body" do
    assert Client.computer_frame("sb-1", 7) == {:ok, :no_change}
  end

  test "a 200 frame decodes normally" do
    assert {:ok, %{"seq" => 8, "imageBase64" => "aGk="}} = Client.computer_frame("sb-1", 0)
  end

  test "a 409 keeps its status so the caller can pass it through" do
    assert {:error, {:http_error, 409, body}} = Client.computer_input("sb-1", %{"kind" => "click"})
    assert body =~ "control_not_held"
  end

  test "the session query rides along on frame and state" do
    assert {:ok, _} = Client.computer_state("sb-1", "sess-1")
    assert {:ok, :no_change} = Client.computer_frame("sb-1", 7, "sess-1")
  end
end
