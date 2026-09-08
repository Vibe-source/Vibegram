defmodule Vibe.Storage do
  @moduledoc """
  Thin facade that selects a storage backend and forwards to it.
  """

  alias Vibe.R2Storage
  alias Vibe.SupabaseStorage

  @doc """
  Returns the configured storage backend: `:supabase` or `:r2`. See the
  module doc for the full selection order.
  """
  def backend do
    case Application.get_env(:vibe, :storage_backend) do
      v when v in [:r2, "r2"] -> :r2
      v when v in [:supabase, "supabase"] -> :supabase
      _ -> autodetect_backend()
    end
  end

  defp autodetect_backend do
    :r2
  end

  @doc "Upload a file through the configured backend. See backend/0."
  def upload(local_path, remote_path), do: upload(local_path, remote_path, [])

  def upload(local_path, remote_path, opts) when is_list(opts) do
    case backend() do
      :r2 -> R2Storage.upload(local_path, remote_path, opts)
      :supabase -> SupabaseStorage.upload(local_path, remote_path, opts)
    end
  end

  @doc "Check existence through the configured backend. See backend/0."
  def exists?(remote_path) do
    case backend() do
      :r2 -> R2Storage.exists?(remote_path)
      :supabase -> SupabaseStorage.exists?(remote_path)
    end
  end

  @doc "Delete through the configured backend. See backend/0."
  def delete(remote_path) do
    case backend() do
      :r2 -> R2Storage.delete(remote_path)
      :supabase -> SupabaseStorage.delete(remote_path)
    end
  end

  @doc """
  Rewrite a stored URL onto whichever CDN fronts the storage it actually lives in.
  """
  def rewrite_public_url(url) do
    case backend() do
      :r2 -> url |> SupabaseStorage.rewrite_public_url() |> R2Storage.rewrite_public_url()
      :supabase -> SupabaseStorage.rewrite_public_url(url)
    end
  end
end
