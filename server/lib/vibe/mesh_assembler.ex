defmodule Vibe.MeshAssembler do
  @moduledoc """
  Server-side fragment reassembly for the mesh relay network.
  """

  use GenServer
  require Logger

  @table :mesh_fragments
  @cleanup_interval_ms 60_000
  @fragment_ttl_ms 30_000

  # Hard caps to keep reconstruction O(threshold^2 * payload_len) bounded.
  @max_threshold 16
  @max_total_shares 32
  @max_payload_len 65_536
  @max_share_data_len 65_536

  # ── Public API ──────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Submit a fragment. Returns `{:ok, payload}` if the set is now complete,
  `:pending` if more fragments are needed, or `{:error, reason}` on failure.
  """
  def submit_fragment(fragment) when is_map(fragment) do
    set_id = fragment["set_id"] || fragment[:set_id]
    threshold = fragment["threshold"] || fragment[:threshold]
    share_index = fragment["share_index"] || fragment[:share_index]
    total_shares = fragment["total_shares"] || fragment[:total_shares]
    payload_len = fragment["payload_len"] || fragment[:payload_len]
    payload_hash = fragment["payload_hash"] || fragment[:payload_hash]
    share_data = fragment["share_data"] || fragment[:share_data]

    with :ok <- require_fields(set_id, threshold, share_index, share_data),
         :ok <- validate_bounds(threshold, total_shares, share_index, payload_len, share_data) do
      entry = %{
        set_id: set_id,
        threshold: threshold,
        share_index: share_index,
        total_shares: total_shares,
        payload_len: payload_len,
        payload_hash: payload_hash,
        share_data: share_data,
        received_at: System.system_time(:millisecond)
      }

      :ets.insert(@table, {{set_id, share_index}, entry})

      all_fragments = get_set_fragments(set_id)

      if length(all_fragments) >= threshold do
        case reconstruct(all_fragments, threshold, payload_len, payload_hash) do
          {:ok, payload} ->
            cleanup_set(set_id)
            Logger.info(
              "[MeshAssembler] Reconstructed set #{set_id} (#{byte_size(payload)} bytes)"
            )

            {:ok, payload}

          {:error, reason} ->
            Logger.warning(
              "[MeshAssembler] Reconstruction failed for set #{set_id}: #{inspect(reason)}"
            )

            :pending
        end
      else
        :pending
      end
    end
  end

  def submit_fragment(_), do: {:error, :invalid_fragment}

  @doc """
  Get stats about pending fragment sets.
  """
  def stats do
    all = :ets.tab2list(@table)
    sets = all |> Enum.map(fn {{set_id, _}, _} -> set_id end) |> Enum.uniq()

    %{
      pending_sets: length(sets),
      total_fragments: length(all)
    }
  end


  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    schedule_cleanup()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.system_time(:millisecond)

    expired =
      :ets.tab2list(@table)
      |> Enum.filter(fn {_key, entry} ->
        now - entry.received_at > @fragment_ttl_ms
      end)

    for {key, _entry} <- expired do
      :ets.delete(@table, key)
    end

    if length(expired) > 0 do
      Logger.debug("[MeshAssembler] Cleaned up #{length(expired)} expired fragments")
    end

    schedule_cleanup()
    {:noreply, state}
  end


  defp require_fields(set_id, threshold, share_index, share_data) do
    if set_id && threshold && share_index && share_data do
      :ok
    else
      {:error, :invalid_fragment}
    end
  end

  defp validate_bounds(threshold, total_shares, share_index, payload_len, share_data) do
    cond do
      not valid_positive_int?(threshold, 1, @max_threshold) ->
        {:error, :invalid_threshold}

      not is_nil(total_shares) and
          not valid_positive_int?(total_shares, threshold, @max_total_shares) ->
        {:error, :invalid_total_shares}

      not valid_positive_int?(share_index, 1, total_shares || @max_total_shares) ->
        {:error, :invalid_share_index}

      not is_nil(payload_len) and not valid_nonneg_int?(payload_len, @max_payload_len) ->
        {:error, :invalid_payload_len}

      not valid_share_data?(share_data, payload_len) ->
        {:error, :invalid_share_data}

      true ->
        :ok
    end
  end

  defp valid_positive_int?(value, min, max)
       when is_integer(value) and value >= min and value <= max,
       do: true

  defp valid_positive_int?(_, _, _), do: false

  defp valid_nonneg_int?(value, max) when is_integer(value) and value >= 0 and value <= max,
    do: true

  defp valid_nonneg_int?(_, _), do: false

  defp valid_share_data?(share_data, payload_len) when is_list(share_data) do
    len = length(share_data)

    len > 0 and len <= @max_share_data_len and
      (is_nil(payload_len) or len == payload_len) and
      Enum.all?(share_data, &share_byte?/1)
  end

  defp valid_share_data?(share_data, payload_len) when is_binary(share_data) do
    len = byte_size(share_data)

    len > 0 and len <= @max_share_data_len and
      (is_nil(payload_len) or len == payload_len)
  end

  defp valid_share_data?(_, _), do: false

  defp share_byte?(b) when is_integer(b) and b >= 0 and b <= 256, do: true
  defp share_byte?(_), do: false

  defp get_set_fragments(set_id) do
    :ets.match_object(@table, {{set_id, :_}, :_})
    |> Enum.map(fn {_key, entry} -> entry end)
  end

  defp cleanup_set(set_id) do
    fragments = :ets.match_object(@table, {{set_id, :_}, :_})

    for {key, _} <- fragments do
      :ets.delete(@table, key)
    end
  end

  defp reconstruct(fragments, threshold, expected_len, expected_hash) do
    sorted = Enum.sort_by(fragments, & &1.share_index) |> Enum.take(threshold)

    field_prime = 257
    payload_len = expected_len || hd(sorted).payload_len

    cond do
      not valid_nonneg_int?(payload_len, @max_payload_len) ->
        {:error, :invalid_payload_len}

      payload_len == 0 ->
        {:error, :invalid_payload_len}

      true ->
        do_reconstruct(sorted, payload_len, expected_hash, field_prime)
    end
  end

  defp do_reconstruct(sorted, payload_len, expected_hash, field_prime) do
    result =
      Enum.reduce_while(0..(payload_len - 1), {:ok, <<>>}, fn offset, {:ok, acc} ->
        secret =
          Enum.reduce(sorted, 0, fn fragment, secret_acc ->
            xi = fragment.share_index
            yi = share_byte_at(fragment.share_data, offset)

            {numerator, denominator} =
              Enum.reduce(sorted, {1, 1}, fn other, {num, den} ->
                if other.share_index == xi do
                  {num, den}
                else
                  xj = other.share_index
                  {mod_prime(num * -xj, field_prime), mod_prime(den * (xi - xj), field_prime)}
                end
              end)

            inv = mod_inverse(denominator, field_prime)
            basis = mod_prime(numerator * inv, field_prime)
            mod_prime(secret_acc + yi * basis, field_prime)
          end)

        if secret >= 0 and secret <= 255 do
          {:cont, {:ok, acc <> <<secret::8>>}}
        else
          {:halt, {:error, "invalid byte at offset #{offset}"}}
        end
      end)

    case result do
      {:ok, payload} ->
        actual_hash = Base.encode16(:crypto.hash(:sha256, payload), case: :lower)

        if expected_hash && actual_hash != expected_hash do
          {:error, "hash mismatch"}
        else
          {:ok, payload}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp share_byte_at(share_data, offset) when is_list(share_data) do
    Enum.at(share_data, offset, 0)
  end

  defp share_byte_at(share_data, offset) when is_binary(share_data) do
    if offset < byte_size(share_data) do
      :binary.at(share_data, offset)
    else
      0
    end
  end

  defp mod_prime(value, prime) do
    result = rem(value, prime)
    if result < 0, do: result + prime, else: result
  end

  defp mod_inverse(value, prime) do
    {_, _, t} = extended_gcd(mod_prime(value, prime), prime)
    mod_prime(t, prime)
  end

  defp extended_gcd(0, b), do: {b, 0, 1}

  defp extended_gcd(a, b) do
    {g, x, y} = extended_gcd(rem(b, a), a)
    {g, y - div(b, a) * x, x}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end
end
