defmodule VibeAgents.Voice.Audio do
  @moduledoc """
  PCM16 mono resampling for the voice audio-in path (16 kHz mic input up to the
  24 kHz the provider expects). Simple linear interpolation — good enough for speech.
  """

  @spec resample_16k_to_24k(binary()) :: binary()
  def resample_16k_to_24k(pcm16), do: resample(pcm16, 16_000, 24_000)

  @spec resample(binary(), pos_integer(), pos_integer()) :: binary()
  def resample(pcm16, rate, rate), do: even(pcm16)

  def resample(pcm16, from_rate, to_rate) do
    samples = pcm16 |> even() |> to_samples()
    n_in = length(samples)

    if n_in < 2 do
      from_samples(samples)
    else
      n_out = max(1, round(n_in * to_rate / from_rate))
      table = List.to_tuple(samples)

      0..(n_out - 1)
      |> Enum.map(&interpolate(table, n_in, n_out, &1))
      |> from_samples()
    end
  end

  defp interpolate(_table, n_in, _n_out, _i) when n_in < 1, do: 0

  defp interpolate(table, n_in, n_out, i) do
    pos = if n_out > 1, do: i * (n_in - 1) / (n_out - 1), else: 0.0
    lo = trunc(pos)
    hi = min(lo + 1, n_in - 1)
    frac = pos - lo
    a = elem(table, lo)
    b = elem(table, hi)
    round(a + (b - a) * frac)
  end

  defp to_samples(bin), do: to_samples(bin, [])
  defp to_samples(<<sample::16-signed-little, rest::binary>>, acc), do: to_samples(rest, [sample | acc])
  defp to_samples(<<>>, acc), do: Enum.reverse(acc)

  defp from_samples(samples), do: for(sample <- samples, into: <<>>, do: <<clamp(sample)::16-signed-little>>)

  defp clamp(sample) when sample > 32_767, do: 32_767
  defp clamp(sample) when sample < -32_768, do: -32_768
  defp clamp(sample), do: sample

  defp even(bin) when rem(byte_size(bin), 2) == 0, do: bin
  defp even(bin), do: binary_part(bin, 0, byte_size(bin) - 1)
end
