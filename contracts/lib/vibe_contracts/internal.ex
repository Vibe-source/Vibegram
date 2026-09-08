defmodule VibeContracts.Internal do
  @moduledoc false
  # Shared helpers for other VibeContracts modules.

  @doc "RFC4122 v4 UUID, dependency-free (no Ecto in this app)."
  @spec uuid4() :: binary()
  def uuid4 do
    <<u0::32, u1::16, _::4, u2::12, _::2, u3::62>> = :crypto.strong_rand_bytes(16)
    <<u0::32, u1::16, 4::4, u2::12, 2::2, u3::62>> |> uuid_to_string()
  end

  defp uuid_to_string(<<u0::32, u1::16, u2::16, u3::16, u4::48>>) do
    ~c"~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b"
    |> :io_lib.format([u0, u1, u2, u3, u4])
    |> IO.iodata_to_binary()
  end
end
