defmodule Vibe.Net.SafeURL do
  @moduledoc false

  import Bitwise

  @spec validate(binary()) :: {:ok, URI.t()} | {:error, term()}
  def validate(url) when is_binary(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme not in ["http", "https"] ->
        {:error, :invalid_scheme}

      is_nil(uri.host) or uri.host == "" ->
        {:error, :missing_host}

      true ->
        validate_host(uri)
    end
  rescue
    ArgumentError -> {:error, :invalid_url}
  end

  def validate(_url), do: {:error, :invalid_url}

  defp validate_host(uri) do
    host = String.to_charlist(uri.host)

    addresses =
      [:inet, :inet6]
      |> Enum.flat_map(fn family ->
        case :inet.getaddrs(host, family) do
          {:ok, resolved} -> resolved
          {:error, _reason} -> []
        end
      end)
      |> Enum.uniq()

    cond do
      addresses == [] -> {:error, :host_not_found}
      Enum.any?(addresses, &blocked_address?/1) -> {:error, :blocked_address}
      true -> {:ok, uri}
    end
  end

  defp blocked_address?({a, b, c, d}), do: blocked_ipv4?(a, b, c, d)

  defp blocked_address?({0, 0, 0, 0, 0, 65_535, high, low}) do
    blocked_ipv4?(high >>> 8, high &&& 255, low >>> 8, low &&& 255)
  end

  defp blocked_address?({0, 0, 0, 0, 0, 0, 0, 1}), do: true

  defp blocked_address?({0, 0, 0, 0, 0, 0, high, low}) do
    blocked_ipv4?(high >>> 8, high &&& 255, low >>> 8, low &&& 255)
  end

  defp blocked_address?({first, _, _, _, _, _, _, _}) when first in 0xFC00..0xFDFF, do: true
  defp blocked_address?({first, _, _, _, _, _, _, _}) when first in 0xFE80..0xFEBF, do: true
  defp blocked_address?(_address), do: false

  defp blocked_ipv4?(a, b, _c, _d) do
    a == 0 or
      a == 10 or
      a == 127 or
      (a == 100 and b in 64..127) or
      (a == 169 and b == 254) or
      (a == 172 and b in 16..31) or
      (a == 192 and b == 168)
  end
end
