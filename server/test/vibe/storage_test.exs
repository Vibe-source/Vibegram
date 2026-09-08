defmodule Vibe.StorageTest do
  @moduledoc """
  `Vibe.Storage.backend/0` decides where every upload in the app lands.
  """

  use ExUnit.Case, async: false

  alias Vibe.Storage

  @r2_env_vars ~w(R2_ACCOUNT_ID R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BUCKET R2_PUBLIC_BASE_URL)

  setup do
    prev_app_env = Application.get_env(:vibe, :r2)
    prev_backend = Application.get_env(:vibe, :storage_backend)
    prev_os_env = for key <- @r2_env_vars, into: %{}, do: {key, System.get_env(key)}

    Application.delete_env(:vibe, :r2)
    Application.delete_env(:vibe, :storage_backend)
    Enum.each(@r2_env_vars, &System.delete_env/1)

    on_exit(fn ->
      restore_app_env(:r2, prev_app_env)
      restore_app_env(:storage_backend, prev_backend)

      Enum.each(prev_os_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    :ok
  end

  describe "backend/0" do
    test "autodetects r2 with nothing configured" do
      assert Storage.backend() == :r2
    end

    test "selects r2 once every required env var is present" do
      set_full_r2_env()
      assert Storage.backend() == :r2
    end

    test "an explicit config wins in both directions" do
      set_full_r2_env()

      Application.put_env(:vibe, :storage_backend, :supabase)
      assert Storage.backend() == :supabase

      Application.put_env(:vibe, :storage_backend, :r2)
      assert Storage.backend() == :r2
    end

    test "partial config still selects r2, and the refusal moves to call time" do
      for omitted <- ~w(R2_ACCOUNT_ID R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BUCKET) do
        set_full_r2_env()
        System.delete_env(omitted)

        assert Storage.backend() == :r2,
               "with #{omitted} missing there is still no second backend to fall back to; " <>
                 "R2Storage refuses the call instead of routing it elsewhere"
      end
    end

    test "an empty-string env var does not change the autodetected backend" do
      set_full_r2_env()
      System.put_env("R2_BUCKET", "   ")
      assert Storage.backend() == :r2
    end

    test "the public base URL is not required to select r2" do
      set_full_r2_env()
      System.delete_env("R2_PUBLIC_BASE_URL")

      assert Storage.backend() == :r2
    end
  end

  describe "rewrite_public_url/1 across a cutover" do
    test "a legacy Supabase URL survives the switch to r2 untouched" do
      set_full_r2_env()

      supabase_url =
        "https://project.supabase.co/storage/v1/object/public/media/abc.jpg"

      assert Storage.rewrite_public_url(supabase_url) == supabase_url
    end

    test "an r2 object URL always uses the durable API relay" do
      set_full_r2_env()

      r2_url = "https://acct.r2.cloudflarestorage.com/vibe-media/abc.jpg"

      assert Storage.rewrite_public_url(r2_url) ==
               "http://localhost:4002/api/media/o/abc.jpg"

      assert Storage.rewrite_public_url("https://cdn.example.com/abc.jpg?download") ==
               "http://localhost:4002/api/media/o/abc.jpg"
    end

    test "an unrelated URL is left alone" do
      set_full_r2_env()
      assert Storage.rewrite_public_url("https://example.com/x.jpg") == "https://example.com/x.jpg"
    end

    test "nil passes through rather than raising" do
      set_full_r2_env()
      assert Storage.rewrite_public_url(nil) == nil
    end
  end

  defp set_full_r2_env do
    System.put_env("R2_ACCOUNT_ID", "acct")
    System.put_env("R2_ACCESS_KEY_ID", "AKIAEXAMPLE00000TEST")
    System.put_env("R2_SECRET_ACCESS_KEY", "test-placeholder-secret-not-a-real-credential")
    System.put_env("R2_BUCKET", "vibe-media")
    System.put_env("R2_PUBLIC_BASE_URL", "https://cdn.example.com")
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:vibe, key)
  defp restore_app_env(key, value), do: Application.put_env(:vibe, key, value)
end
