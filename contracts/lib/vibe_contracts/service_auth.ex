defmodule VibeContracts.ServiceAuth do
  @moduledoc """
  `vibe-internal-auth/v1` — HMAC request signing/verification shared by core and
  agent-runtime. Keys must be >= 32 raw bytes; verification is constant-time.
  """

  @nonce_ttl_seconds 600
  @default_tolerance_seconds 300
  @default_allowed_services ["core", "agent-runtime"]
  @required_headers ~w(x-vibe-service x-vibe-timestamp x-vibe-nonce x-vibe-signature)

  @type sign_error :: {:error, :weak_key}
  @type verify_error ::
          {:error,
           :missing_headers
           | :bad_signature
           | :stale_timestamp
           | :replayed_nonce
           | :nonce_store_unavailable
           | :unknown_service
           | :weak_key}

  @doc """
  Signs a request and returns the 4 header names/values as a map.
  `opts`: `service:` (required), `timestamp:` (default now, seconds), `nonce:` (default uuid4).
  """
  @spec sign(binary(), binary(), binary(), binary(), keyword()) :: map() | sign_error()
  def sign(key, method, path_with_query, body, opts \\ []) do
    case build_headers(key, method, path_with_query, body, opts) do
      {:ok, headers} -> headers
      {:error, _} = error -> error
    end
  end

  @doc "Same as `sign/5` but returns a list of `{name, value}` tuples."
  @spec headers(binary(), binary(), binary(), binary(), keyword()) ::
          [{binary(), binary()}] | sign_error()
  def headers(key, method, path_with_query, body, opts \\ []) do
    case build_headers(key, method, path_with_query, body, opts) do
      {:ok, headers} -> Enum.into(headers, [])
      {:error, _} = error -> error
    end
  end

  @doc """
  Verifies a signed request; `headers` is a map or a list of `{name, value}` pairs.
  `opts`: `now:`, `tolerance_seconds:` (300), `nonce_seen?:` (default ETS replay cache), `allowed_services:`.
  """
  @spec verify(binary(), binary(), binary(), binary(), map() | list(), keyword()) ::
          :ok | verify_error()
  def verify(key, method, path_with_query, body, headers, opts \\ []) do
    with :ok <- check_key_strength(key),
         {:ok, hmap} <- extract_headers(headers),
         :ok <- check_service(hmap, opts),
         :ok <- check_timestamp(hmap, opts),
         :ok <- check_signature(key, method, path_with_query, body, hmap),
         :ok <- check_nonce(hmap, opts) do
      :ok
    end
  end

  @doc "Constant-time binary comparison; unequal lengths short-circuit to false."
  @spec secure_compare(binary(), binary()) :: boolean()
  def secure_compare(a, b) when is_binary(a) and is_binary(b) and byte_size(a) == byte_size(b) do
    a
    |> :binary.bin_to_list()
    |> Enum.zip(:binary.bin_to_list(b))
    |> Enum.reduce(0, fn {x, y}, acc -> Bitwise.bor(acc, Bitwise.bxor(x, y)) end)
    |> Kernel.==(0)
  end

  def secure_compare(_a, _b), do: false

  defp build_headers(key, method, path_with_query, body, opts) do
    with :ok <- check_key_strength(key) do
      service = Keyword.fetch!(opts, :service)
      ts = opts |> Keyword.get(:timestamp) |> normalize_timestamp()
      nonce = Keyword.get(opts, :nonce) || generate_nonce()
      signature = compute_signature(key, service, method, path_with_query, ts, nonce, body)

      {:ok,
       %{
         "x-vibe-service" => service,
         "x-vibe-timestamp" => ts,
         "x-vibe-nonce" => nonce,
         "x-vibe-signature" => "v1=" <> signature
       }}
    end
  end

  defp normalize_timestamp(nil), do: Integer.to_string(System.system_time(:second))
  defp normalize_timestamp(ts) when is_integer(ts), do: Integer.to_string(ts)
  defp normalize_timestamp(ts) when is_binary(ts), do: ts

  defp check_key_strength(key) when is_binary(key) and byte_size(key) >= 32, do: :ok
  defp check_key_strength(_key), do: {:error, :weak_key}

  defp extract_headers(headers) when is_map(headers), do: normalize_header_map(headers)

  defp extract_headers(headers) when is_list(headers) do
    headers |> Map.new() |> normalize_header_map()
  end

  defp extract_headers(_headers), do: {:error, :missing_headers}

  defp normalize_header_map(map) do
    downcased = Map.new(map, fn {k, v} -> {String.downcase(to_string(k)), v} end)

    if Enum.all?(@required_headers, fn h -> is_binary(downcased[h]) and downcased[h] != "" end) do
      {:ok, downcased}
    else
      {:error, :missing_headers}
    end
  end

  defp check_service(hmap, opts) do
    allowed = Keyword.get(opts, :allowed_services, @default_allowed_services)
    if hmap["x-vibe-service"] in allowed, do: :ok, else: {:error, :unknown_service}
  end

  defp check_timestamp(hmap, opts) do
    now = Keyword.get(opts, :now) || System.system_time(:second)
    tolerance = Keyword.get(opts, :tolerance_seconds, @default_tolerance_seconds)

    case Integer.parse(hmap["x-vibe-timestamp"]) do
      {ts, ""} -> if abs(now - ts) <= tolerance, do: :ok, else: {:error, :stale_timestamp}
      _ -> {:error, :stale_timestamp}
    end
  end

  defp check_signature(key, method, path_with_query, body, hmap) do
    expected =
      compute_signature(
        key,
        hmap["x-vibe-service"],
        method,
        path_with_query,
        hmap["x-vibe-timestamp"],
        hmap["x-vibe-nonce"],
        body
      )

    case hmap["x-vibe-signature"] do
      "v1=" <> hex -> if secure_compare(hex, expected), do: :ok, else: {:error, :bad_signature}
      _ -> {:error, :bad_signature}
    end
  end

  defp check_nonce(hmap, opts) do
    nonce_seen? = Keyword.get(opts, :nonce_seen?, &default_nonce_seen?/1)

    case nonce_seen?.(hmap["x-vibe-nonce"]) do
      false -> :ok
      true -> {:error, :replayed_nonce}
      _unavailable -> {:error, :nonce_store_unavailable}
    end
  end

  defp compute_signature(key, service, method, path_with_query, ts, nonce, body) do
    signing_string =
      "v1\n" <>
        service <>
        "\n" <>
        String.upcase(method) <>
        "\n" <>
        path_with_query <> "\n" <> to_string(ts) <> "\n" <> nonce <> "\n" <> sha256_hex(body)

    :hmac
    |> :crypto.mac(:sha256, key, signing_string)
    |> Base.encode16(case: :lower)
  end

  defp sha256_hex(body), do: :sha256 |> :crypto.hash(body || "") |> Base.encode16(case: :lower)

  defp generate_nonce, do: VibeContracts.Internal.uuid4()

  defp default_nonce_seen?(nonce),
    do: VibeContracts.NonceStore.seen?(nonce, @nonce_ttl_seconds)

end
