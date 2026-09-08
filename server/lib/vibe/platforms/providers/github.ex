defmodule Vibe.Platforms.Providers.GitHub do
  @moduledoc """
  GitHub OAuth connector for PR review/create/comment and issue workflows.
  """

  @behaviour Vibe.Platforms.Provider

  require Logger

  @api "https://api.github.com"
  @authorize "https://github.com/login/oauth/authorize"
  @token_url "https://github.com/login/oauth/access_token"

  @impl true
  def id, do: "github"

  @impl true
  def name, do: "GitHub"

  @impl true
  def description,
    do: "Review pull requests, comment, list issues, and work on repos with coding agents."

  @impl true
  def icon, do: "github"

  @impl true
  def category, do: "engineering"

  @impl true
  def oauth_configured? do
    present?(client_id()) and present?(client_secret())
  end

  @impl true
  def default_scopes, do: ~w[read:user user:email repo]

  @impl true
  def capabilities do
    [
      %{
        id: "list_repos",
        name: "List repositories",
        description: "List repositories the connected account can access.",
        risk: "low",
        params: %{
          "visibility" => "all | public | private (optional)",
          "per_page" => "1-50 (optional)"
        }
      },
      %{
        id: "list_pull_requests",
        name: "List pull requests",
        description: "List open or closed PRs for owner/repo.",
        risk: "low",
        params: %{
          "owner" => "org or user",
          "repo" => "repository name",
          "state" => "open | closed | all (optional)",
          "per_page" => "1-50 (optional)"
        }
      },
      %{
        id: "get_pull_request",
        name: "Get pull request",
        description: "Fetch PR title, body, state, author, and branch metadata.",
        risk: "low",
        params: %{"owner" => "required", "repo" => "required", "number" => "PR number"}
      },
      %{
        id: "list_pr_files",
        name: "List PR files",
        description: "List files changed in a pull request with patch summaries.",
        risk: "low",
        params: %{"owner" => "required", "repo" => "required", "number" => "PR number"}
      },
      %{
        id: "list_pr_comments",
        name: "List PR comments",
        description: "List issue-style comments on a pull request.",
        risk: "low",
        params: %{"owner" => "required", "repo" => "required", "number" => "PR number"}
      },
      %{
        id: "create_pr_comment",
        name: "Comment on PR",
        description: "Post a review comment on a pull request.",
        risk: "medium",
        params: %{
          "owner" => "required",
          "repo" => "required",
          "number" => "PR number",
          "body" => "markdown comment body"
        }
      },
      %{
        id: "create_issue",
        name: "Create issue",
        description: "Open a GitHub issue.",
        risk: "medium",
        params: %{
          "owner" => "required",
          "repo" => "required",
          "title" => "required",
          "body" => "optional markdown"
        }
      },
      %{
        id: "list_issues",
        name: "List issues",
        description: "List repository issues (excludes PRs when possible).",
        risk: "low",
        params: %{
          "owner" => "required",
          "repo" => "required",
          "state" => "open | closed | all (optional)"
        }
      },
      %{
        id: "get_repo",
        name: "Get repository",
        description: "Fetch repository metadata (default branch, visibility, description).",
        risk: "low",
        params: %{"owner" => "required", "repo" => "required"}
      }
    ]
  end

  @impl true
  def authorize_url(state, scopes) when is_binary(state) do
    if oauth_configured?() do
      scope = scopes |> Enum.uniq() |> Enum.join(" ")

      query =
        URI.encode_query(%{
          "client_id" => client_id(),
          "redirect_uri" => redirect_uri(),
          "scope" => scope,
          "state" => state,
          "allow_signup" => "false"
        })

      {:ok, @authorize <> "?" <> query}
    else
      {:error, :oauth_not_configured}
    end
  end

  @impl true
  def exchange_code(code) when is_binary(code) do
    body =
      Jason.encode!(%{
        "client_id" => client_id(),
        "client_secret" => client_secret(),
        "code" => code,
        "redirect_uri" => redirect_uri()
      })

    headers = [
      {"content-type", "application/json"},
      {"accept", "application/json"},
      {"user-agent", "VibePlatforms/1.0"}
    ]

    request = Finch.build(:post, @token_url, headers, body)

    case Finch.request(request, Vibe.Finch, receive_timeout: 15_000) do
      {:ok, %Finch.Response{status: status, body: resp}} when status in 200..299 ->
        case Jason.decode(resp) do
          {:ok, %{"access_token" => token} = payload} when is_binary(token) and token != "" ->
            scopes =
              payload
              |> Map.get("scope", "")
              |> to_string()
              |> String.split([",", " "], trim: true)

            {:ok,
             %{
               access_token: token,
               refresh_token: Map.get(payload, "refresh_token"),
               token_type: Map.get(payload, "token_type", "bearer"),
               scopes: scopes,
               expires_in: Map.get(payload, "expires_in")
             }}

          {:ok, %{"error" => err} = payload} ->
            {:error, {:oauth_exchange_failed, err, Map.get(payload, "error_description")}}

          _ ->
            {:error, :oauth_exchange_invalid_response}
        end

      {:ok, %Finch.Response{status: status, body: resp}} ->
        {:error, {:oauth_exchange_http, status, String.slice(to_string(resp), 0, 200)}}

      {:error, reason} ->
        {:error, {:oauth_exchange_request_failed, reason}}
    end
  end

  def exchange_code(_), do: {:error, :invalid_code}

  @impl true
  def refresh_tokens(refresh_token) when is_binary(refresh_token) and refresh_token != "" do
    body =
      Jason.encode!(%{
        "client_id" => client_id(),
        "client_secret" => client_secret(),
        "grant_type" => "refresh_token",
        "refresh_token" => refresh_token
      })

    headers = [
      {"content-type", "application/json"},
      {"accept", "application/json"},
      {"user-agent", "VibePlatforms/1.0"}
    ]

    request = Finch.build(:post, @token_url, headers, body)

    case Finch.request(request, Vibe.Finch, receive_timeout: 15_000) do
      {:ok, %Finch.Response{status: status, body: resp}} when status in 200..299 ->
        case Jason.decode(resp) do
          {:ok, %{"access_token" => token} = payload} when is_binary(token) ->
            {:ok,
             %{
               access_token: token,
               refresh_token: Map.get(payload, "refresh_token", refresh_token),
               expires_in: Map.get(payload, "expires_in"),
               scopes:
                 payload
                 |> Map.get("scope", "")
                 |> to_string()
                 |> String.split([",", " "], trim: true)
             }}

          _ ->
            {:error, :refresh_failed}
        end

      _ ->
        {:error, :refresh_failed}
    end
  end

  def refresh_tokens(_), do: {:error, :no_refresh_token}

  @impl true
  def fetch_identity(access_token) when is_binary(access_token) do
    with {:ok, user} <- gh_get(access_token, "/user") do
      {:ok,
       %{
         external_account_id: to_string(user["id"]),
         external_account_login: user["login"],
         display_name: user["name"] || user["login"],
         metadata: %{
           "avatar_url" => user["avatar_url"],
           "html_url" => user["html_url"],
           "type" => user["type"]
         }
       }}
    end
  end

  def fetch_identity(_), do: {:error, :invalid_token}

  @impl true
  def invoke_action(access_token, action, params) when is_binary(access_token) do
    params = stringify_keys(params || %{})

    case action do
      "list_repos" ->
        visibility = params["visibility"] || "all"
        per_page = clamp_int(params["per_page"], 30, 1, 50)

        path =
          "/user/repos?per_page=#{per_page}&sort=updated&visibility=#{URI.encode_www_form(visibility)}"

        with {:ok, repos} <- gh_get(access_token, path) do
          {:ok,
           %{
             "items" =>
               Enum.map(List.wrap(repos), fn repo ->
                 %{
                   "full_name" => repo["full_name"],
                   "private" => repo["private"],
                   "default_branch" => repo["default_branch"],
                   "html_url" => repo["html_url"],
                   "description" => repo["description"],
                   "language" => repo["language"],
                   "updated_at" => repo["updated_at"]
                 }
               end)
           }}
        end

      "list_pull_requests" ->
        with {:ok, owner, repo} <- require_owner_repo(params) do
          state = params["state"] || "open"
          per_page = clamp_int(params["per_page"], 20, 1, 50)
          path = "/repos/#{owner}/#{repo}/pulls?state=#{state}&per_page=#{per_page}&sort=updated"

          with {:ok, prs} <- gh_get(access_token, path) do
            {:ok,
             %{
               "items" =>
                 Enum.map(List.wrap(prs), fn pr ->
                   %{
                     "number" => pr["number"],
                     "title" => pr["title"],
                     "state" => pr["state"],
                     "user" => get_in(pr, ["user", "login"]),
                     "html_url" => pr["html_url"],
                     "draft" => pr["draft"],
                     "created_at" => pr["created_at"],
                     "updated_at" => pr["updated_at"],
                     "head" => get_in(pr, ["head", "ref"]),
                     "base" => get_in(pr, ["base", "ref"])
                   }
                 end)
             }}
          end
        end

      "get_pull_request" ->
        with {:ok, owner, repo} <- require_owner_repo(params),
             {:ok, number} <- require_number(params),
             {:ok, pr} <- gh_get(access_token, "/repos/#{owner}/#{repo}/pulls/#{number}") do
          {:ok,
           %{
             "number" => pr["number"],
             "title" => pr["title"],
             "body" => truncate(pr["body"], 8_000),
             "state" => pr["state"],
             "merged" => pr["merged"],
             "draft" => pr["draft"],
             "user" => get_in(pr, ["user", "login"]),
             "html_url" => pr["html_url"],
             "head" => get_in(pr, ["head", "ref"]),
             "base" => get_in(pr, ["base", "ref"]),
             "additions" => pr["additions"],
             "deletions" => pr["deletions"],
             "changed_files" => pr["changed_files"],
             "mergeable_state" => pr["mergeable_state"]
           }}
        end

      "list_pr_files" ->
        with {:ok, owner, repo} <- require_owner_repo(params),
             {:ok, number} <- require_number(params),
             {:ok, files} <-
               gh_get(access_token, "/repos/#{owner}/#{repo}/pulls/#{number}/files?per_page=100") do
          {:ok,
           %{
             "items" =>
               Enum.map(List.wrap(files), fn file ->
                 %{
                   "filename" => file["filename"],
                   "status" => file["status"],
                   "additions" => file["additions"],
                   "deletions" => file["deletions"],
                   "changes" => file["changes"],
                   "patch" => truncate(file["patch"], 4_000)
                 }
               end)
           }}
        end

      "list_pr_comments" ->
        with {:ok, owner, repo} <- require_owner_repo(params),
             {:ok, number} <- require_number(params),
             {:ok, comments} <-
               gh_get(
                 access_token,
                 "/repos/#{owner}/#{repo}/issues/#{number}/comments?per_page=50"
               ) do
          {:ok,
           %{
             "items" =>
               Enum.map(List.wrap(comments), fn c ->
                 %{
                   "id" => c["id"],
                   "user" => get_in(c, ["user", "login"]),
                   "body" => truncate(c["body"], 2_000),
                   "created_at" => c["created_at"],
                   "html_url" => c["html_url"]
                 }
               end)
           }}
        end

      "create_pr_comment" ->
        with {:ok, owner, repo} <- require_owner_repo(params),
             {:ok, number} <- require_number(params),
             {:ok, body} <- require_string(params, "body"),
             {:ok, comment} <-
               gh_post(access_token, "/repos/#{owner}/#{repo}/issues/#{number}/comments", %{
                 "body" => body
               }) do
          {:ok,
           %{
             "id" => comment["id"],
             "html_url" => comment["html_url"],
             "created_at" => comment["created_at"]
           }}
        end

      "create_issue" ->
        with {:ok, owner, repo} <- require_owner_repo(params),
             {:ok, title} <- require_string(params, "title"),
             {:ok, issue} <-
               gh_post(access_token, "/repos/#{owner}/#{repo}/issues", %{
                 "title" => title,
                 "body" => params["body"] || ""
               }) do
          {:ok,
           %{
             "number" => issue["number"],
             "html_url" => issue["html_url"],
             "title" => issue["title"],
             "state" => issue["state"]
           }}
        end

      "list_issues" ->
        with {:ok, owner, repo} <- require_owner_repo(params) do
          state = params["state"] || "open"
          path = "/repos/#{owner}/#{repo}/issues?state=#{state}&per_page=30"

          with {:ok, issues} <- gh_get(access_token, path) do
            items =
              issues
              |> List.wrap()
              |> Enum.reject(fn i -> is_map(i["pull_request"]) end)
              |> Enum.map(fn i ->
                %{
                  "number" => i["number"],
                  "title" => i["title"],
                  "state" => i["state"],
                  "user" => get_in(i, ["user", "login"]),
                  "html_url" => i["html_url"],
                  "created_at" => i["created_at"]
                }
              end)

            {:ok, %{"items" => items}}
          end
        end

      "get_repo" ->
        with {:ok, owner, repo} <- require_owner_repo(params),
             {:ok, r} <- gh_get(access_token, "/repos/#{owner}/#{repo}") do
          {:ok,
           %{
             "full_name" => r["full_name"],
             "private" => r["private"],
             "default_branch" => r["default_branch"],
             "description" => r["description"],
             "html_url" => r["html_url"],
             "language" => r["language"],
             "open_issues_count" => r["open_issues_count"]
           }}
        end

      _ ->
        {:error, {:unknown_action, action}}
    end
  end

  def invoke_action(_, _, _), do: {:error, :invalid_token}


  defp gh_get(token, path) do
    request =
      Finch.build(:get, @api <> path, auth_headers(token))

    case Finch.request(request, Vibe.Finch, receive_timeout: 20_000) do
      {:ok, %Finch.Response{status: status, body: body}} when status in 200..299 ->
        decode_json(body)

      {:ok, %Finch.Response{status: 401, body: body}} ->
        Logger.warning("[GitHub] unauthorized path=#{path}")
        {:error, {:github_unauthorized, summarize(body)}}

      {:ok, %Finch.Response{status: 403, body: body}} ->
        {:error, {:github_forbidden, summarize(body)}}

      {:ok, %Finch.Response{status: 404, body: body}} ->
        {:error, {:github_not_found, summarize(body)}}

      {:ok, %Finch.Response{status: status, body: body}} ->
        {:error, {:github_http, status, summarize(body)}}

      {:error, reason} ->
        {:error, {:github_request_failed, reason}}
    end
  end

  defp gh_post(token, path, payload) do
    request =
      Finch.build(
        :post,
        @api <> path,
        auth_headers(token) ++ [{"content-type", "application/json"}],
        Jason.encode!(payload)
      )

    case Finch.request(request, Vibe.Finch, receive_timeout: 20_000) do
      {:ok, %Finch.Response{status: status, body: body}} when status in 200..299 ->
        decode_json(body)

      {:ok, %Finch.Response{status: status, body: body}} ->
        {:error, {:github_http, status, summarize(body)}}

      {:error, reason} ->
        {:error, {:github_request_failed, reason}}
    end
  end

  defp auth_headers(token) do
    [
      {"authorization", "Bearer #{token}"},
      {"accept", "application/vnd.github+json"},
      {"user-agent", "VibePlatforms/1.0"},
      {"x-github-api-version", "2022-11-28"}
    ]
  end

  defp decode_json(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      _ -> {:error, :invalid_json}
    end
  end

  defp require_owner_repo(params) do
    owner = normalize_repo_part(params["owner"])
    repo = normalize_repo_part(params["repo"])

    if owner && repo do
      {:ok, owner, repo}
    else
      {:error, :missing_owner_or_repo}
    end
  end

  defp require_number(params) do
    case params["number"] || params["pr"] || params["pull_number"] do
      n when is_integer(n) and n > 0 ->
        {:ok, n}

      n when is_binary(n) ->
        case Integer.parse(String.trim(n)) do
          {i, _} when i > 0 -> {:ok, i}
          _ -> {:error, :invalid_number}
        end

      _ ->
        {:error, :missing_number}
    end
  end

  defp require_string(params, key) do
    case params[key] do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: {:error, {:missing, key}}, else: {:ok, trimmed}

      _ ->
        {:error, {:missing, key}}
    end
  end

  defp normalize_repo_part(value) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed != "" and Regex.match?(~r/^[A-Za-z0-9_.-]+$/, trimmed) do
      trimmed
    else
      nil
    end
  end

  defp normalize_repo_part(_), do: nil

  defp clamp_int(value, default, min, max) do
    n =
      cond do
        is_integer(value) ->
          value

        is_binary(value) ->
          case Integer.parse(String.trim(value)) do
            {i, _} -> i
            :error -> default
          end

        true ->
          default
      end

    n |> max(min) |> min(max)
  end

  defp truncate(nil, _), do: nil

  defp truncate(value, max) when is_binary(value) and byte_size(value) > max do
    binary_part(value, 0, max) <> "…"
  end

  defp truncate(value, _), do: value

  defp summarize(body) when is_binary(body), do: String.slice(body, 0, 200)
  defp summarize(_), do: ""

  defp stringify_keys(map) when is_map(map) do
    Enum.into(map, %{}, fn {k, v} -> {to_string(k), v} end)
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false

  defp client_id,
    do: System.get_env("GITHUB_CLIENT_ID") || System.get_env("VIBE_GITHUB_CLIENT_ID")

  defp client_secret,
    do: System.get_env("GITHUB_CLIENT_SECRET") || System.get_env("VIBE_GITHUB_CLIENT_SECRET")

  defp redirect_uri do
    System.get_env("VIBE_GITHUB_REDIRECT_URI") ||
      System.get_env("GITHUB_REDIRECT_URI") ||
      public_base_url() <> "/api/platforms/oauth/github/callback"
  end

  @doc """
  Public HTTPS base for OAuth callbacks and absolute API links.
  """
  def public_base_url do
    base =
      present_env("VIBE_PUBLIC_BASE_URL") ||
        present_env("PUBLIC_BASE_URL") ||
        case present_env("PHX_HOST") do
          nil -> "https://api.vibegram.io"
          host -> host
        end

    normalize_public_base(base)
  end

  defp present_env(name) do
    case System.get_env(name) do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: nil, else: trimmed

      _ ->
        nil
    end
  end

  defp normalize_public_base(base) do
    trimmed = String.trim_trailing(String.trim(base), "/")

    if String.starts_with?(trimmed, "http://") or String.starts_with?(trimmed, "https://") do
      trimmed
    else
      "https://" <> trimmed
    end
  end
end
