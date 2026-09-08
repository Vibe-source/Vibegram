defmodule VibeAgents.Tools.BrowserTest do
  @moduledoc "browser_open / browser_act emit run.computer.state once per real navigation."
  use ExUnit.Case, async: false
  import Ecto.Query

  alias VibeAgents.Repo
  alias VibeAgents.Schemas.{AgentComputer, AgentRunEvent}
  alias VibeAgents.Test.{Fixtures, FakeSandboxHTTP}
  alias VibeAgents.Tools.Browser

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    FakeSandboxHTTP.reset()
    Application.put_env(:vibe_agents, :sandbox_gateway_url, "http://gateway.test")
    Application.put_env(:vibe_agents, :sandbox_gateway_token, String.duplicate("t", 40))

    on_exit(fn ->
      FakeSandboxHTTP.reset()
      Application.delete_env(:vibe_agents, :sandbox_gateway_url)
      Application.delete_env(:vibe_agents, :sandbox_gateway_token)
    end)

    run = Fixtures.insert_run!(%{"capabilities" => %{"browser" => true, "network" => "allowlist"}})

    %AgentComputer{}
    |> AgentComputer.changeset(%{
      agent_id: run.agent_id,
      sandbox_id: "sb-9",
      status: "running",
      last_used_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()

    %{run: run}
  end

  defp states(run) do
    Repo.all(
      from(e in AgentRunEvent,
        where: e.run_id == ^run.id and e.kind == "run.computer.state",
        order_by: e.seq,
        select: e.payload
      )
    )
  end

  defp answer(page), do: FakeSandboxHTTP.stub(fn :post, _url, _body -> {:ok, page} end)

  test "a navigation emits one run.computer.state and does not repeat it for the same page", %{run: run} do
    answer(%{"url" => "https://instagram.com/", "title" => "Instagram"})

    assert %{"ok" => true} = Browser.browser_open(run, %{"url" => "https://instagram.com/"}, fn _ -> :ok end)
    assert [%{"url" => "https://instagram.com/", "title" => "Instagram", "live" => true}] = states(run)

    assert %{"ok" => true} = Browser.browser_open(run, %{"url" => "https://instagram.com/"}, fn _ -> :ok end)
    assert length(states(run)) == 1
  end

  test "a different page emits again", %{run: run} do
    answer(%{"url" => "https://instagram.com/", "title" => "Instagram"})
    Browser.browser_open(run, %{"url" => "https://instagram.com/"}, fn _ -> :ok end)

    answer(%{"url" => "https://instagram.com/explore", "title" => "Explore"})
    Browser.browser_open(run, %{"url" => "https://instagram.com/explore"}, fn _ -> :ok end)

    assert [%{"url" => "https://instagram.com/"}, %{"url" => "https://instagram.com/explore", "title" => "Explore"}] = states(run)
  end

  test "a failed navigation emits nothing", %{run: run} do
    FakeSandboxHTTP.stub(fn :post, _url, _body -> {:error, {:http_error, 502, "denied_domain"}} end)

    assert %{"ok" => false} = Browser.browser_open(run, %{"url" => "https://evil.test/"}, fn _ -> :ok end)
    assert states(run) == []
  end

  test "browser_act emits on success and stays quiet when the action failed", %{run: run} do
    answer(%{"ok" => true, "url" => "https://instagram.com/inbox", "title" => "Inbox"})
    assert %{"ok" => true} = Browser.browser_act(run, %{"kind" => "click", "selector" => "#a"}, fn _ -> :ok end)
    assert [%{"url" => "https://instagram.com/inbox"}] = states(run)

    answer(%{"ok" => false, "url" => "https://instagram.com/other", "title" => "Other"})
    assert %{"ok" => false} = Browser.browser_act(run, %{"kind" => "click", "selector" => "#b"}, fn _ -> :ok end)
    assert length(states(run)) == 1
  end
end
