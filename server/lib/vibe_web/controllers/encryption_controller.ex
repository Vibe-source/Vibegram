defmodule VibeWeb.EncryptionController do
  use VibeWeb, :controller
  # alias Vibe.Encryption

  def get_bundle(conn, %{"id" => id}) do
    json(conn, %{
      identityKey: "placeholder",
      signedPreKey: "placeholder",
      signedPreKeySignature: "placeholder"
    })
  end

  def upload_bundle(conn, _params) do
    json(conn, %{success: true})
  end
end
