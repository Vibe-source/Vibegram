defmodule VibeContracts.WebhookSignature do
  @moduledoc """
  Provider callback signing: `t=<ts>,v1=<hex>` over `"<ts>.<body>"`. `verify/4`
  accepts a header with multiple `v1=` entries (secret rotation window).
  """

  alias VibeContracts.ServiceAuth

  @default_tolerance_seconds 300

  @doc "Signs `body` at `ts` (unix seconds) with `secret`, returning `t=<ts>,v1=<hex>`."
  @spec sign(binary(), binary(), integer() | binary()) :: binary()
  def sign(secret, body, ts), do: "t=#{ts},v1=#{compute(secret, ts, body)}"

  @doc """
  Verifies `header` against `secret`/`body`. `opts`: `now:`, `tolerance_seconds:` (300).
  Any matching `v1=` entry in the header passes (supports signing-secret rotation).
  """
  @spec verify(binary(), binary(), binary(), keyword()) ::
          :ok | {:error, :missing_header | :malformed_header | :stale_timestamp | :bad_signature}
  def verify(secret, body, header, opts \\ []) do
    with {:ok, ts, signatures} <- parse_header(header),
         :ok <- check_timestamp(ts, opts) do
      expected = compute(secret, ts, body)

      if Enum.any?(signatures, &ServiceAuth.secure_compare(&1, expected)) do
        :ok
      else
        {:error, :bad_signature}
      end
    end
  end

  defp compute(secret, ts, body) do
    :hmac
    |> :crypto.mac(:sha256, secret, "#{ts}.#{body}")
    |> Base.encode16(case: :lower)
  end

  defp parse_header(header) when is_binary(header) do
    parts = header |> String.split(",") |> Enum.map(&String.trim/1)

    ts =
      Enum.find_value(parts, fn part ->
        case String.split(part, "=", parts: 2) do
          ["t", value] -> value
          _ -> nil
        end
      end)

    signatures =
      parts
      |> Enum.filter(&String.starts_with?(&1, "v1="))
      |> Enum.map(&String.replace_prefix(&1, "v1=", ""))

    if is_binary(ts) and signatures != [] do
      {:ok, ts, signatures}
    else
      {:error, :malformed_header}
    end
  end

  defp parse_header(_header), do: {:error, :missing_header}

  defp check_timestamp(ts, opts) do
    now = Keyword.get(opts, :now) || System.system_time(:second)
    tolerance = Keyword.get(opts, :tolerance_seconds, @default_tolerance_seconds)

    case Integer.parse(ts) do
      {parsed, ""} -> if abs(now - parsed) <= tolerance, do: :ok, else: {:error, :stale_timestamp}
      _ -> {:error, :stale_timestamp}
    end
  end
end
