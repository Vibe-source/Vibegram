defmodule VibeAgents.Voice.SafeApplyTest do
  use ExUnit.Case, async: true

  alias VibeAgents.Voice.SafeApply

  defmodule Real do
    @moduledoc false
    def double(x), do: x * 2
    def boom(_x), do: raise("boom")
  end

  test "calls the function when it's loaded and exported" do
    assert SafeApply.call(Real, :double, [21], :fallback) == 42
  end

  test "falls back when the module doesn't exist" do
    assert SafeApply.call(NoSuchModuleAtAll, :double, [21], :fallback) == :fallback
  end

  test "falls back when the function isn't exported at that arity" do
    assert SafeApply.call(Real, :double, [1, 2], :fallback) == :fallback
  end

  test "falls back when the call raises" do
    assert SafeApply.call(Real, :boom, [1], :fallback) == :fallback
  end
end
