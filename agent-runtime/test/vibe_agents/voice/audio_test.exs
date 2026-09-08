defmodule VibeAgents.Voice.AudioTest do
  use ExUnit.Case, async: true

  alias VibeAgents.Voice.Audio

  defp pcm(samples), do: for(s <- samples, into: <<>>, do: <<s::16-signed-little>>)
  defp samples(bin), do: for(<<s::16-signed-little <- bin>>, do: s)

  test "same-rate resample is a passthrough" do
    input = pcm([0, 100, -100, 32_767, -32_768])
    assert Audio.resample(input, 24_000, 24_000) == input
  end

  test "16k -> 24k upsamples by 1.5x and preserves the first and last sample" do
    input = pcm([0, 1000, 2000, 3000])
    output = Audio.resample_16k_to_24k(input)
    out_samples = samples(output)

    assert length(out_samples) == 6
    assert List.first(out_samples) == 0
    assert List.last(out_samples) == 3000
  end

  test "drops a stray trailing odd byte instead of crashing" do
    input = pcm([100, 200]) <> <<7>>
    output = Audio.resample_16k_to_24k(input)
    assert rem(byte_size(output), 2) == 0
  end

  test "empty input resamples to empty output" do
    assert Audio.resample_16k_to_24k(<<>>) == <<>>
  end
end
