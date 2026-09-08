defmodule Vibe.Platforms.TokenVault do
  @moduledoc """
  AES-256-GCM vault for OAuth access/refresh tokens.
  """

  @aad "vibe.platform.token.v1"

  def encrypt(plaintext) when is_binary(plaintext) and plaintext != "" do
    iv = :crypto.strong_rand_bytes(12)
    key = encryption_key()

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, @aad, 16, true)

    {:ok,
     Enum.join(
       [
         "ags1",
         Base.url_encode64(iv, padding: false),
         Base.url_encode64(ciphertext, padding: false),
         Base.url_encode64(tag, padding: false)
       ],
       "."
     )}
  rescue
    error -> {:error, {:token_encryption_failed, error}}
  end

  def encrypt(_), do: {:error, :invalid_token}

  def decrypt(ciphertext) when is_binary(ciphertext) do
    with ["ags1", iv_b64, data_b64, tag_b64] <- String.split(ciphertext, ".", parts: 4),
         {:ok, iv} <- Base.url_decode64(iv_b64, padding: false),
         {:ok, encrypted} <- Base.url_decode64(data_b64, padding: false),
         {:ok, tag} <- Base.url_decode64(tag_b64, padding: false) do
      case :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             encryption_key(),
             iv,
             encrypted,
             @aad,
             tag,
             false
           ) do
        :error -> {:error, :token_decryption_failed}
        plaintext when is_binary(plaintext) -> {:ok, plaintext}
      end
    else
      _ -> {:error, :token_decryption_failed}
    end
  rescue
    _ -> {:error, :token_decryption_failed}
  end

  def decrypt(_), do: {:error, :token_decryption_failed}

  defp encryption_key do
    seed =
      System.get_env("VIBE_PLATFORM_TOKEN_ENCRYPTION_KEY") ||
        System.get_env("VIBE_AGENT_SECRET_ENCRYPTION_KEY") ||
        System.get_env("VIBE_HMAC_SECRET") ||
        System.get_env("SECRET_KEY_BASE") ||
        "vibe-dev-platform-token-key-not-for-production"

    :crypto.hash(:sha256, seed)
  end
end
