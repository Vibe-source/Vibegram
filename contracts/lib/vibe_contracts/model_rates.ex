defmodule VibeContracts.ModelRates do
  @moduledoc "Cents-per-1,000-token rates per provider/model, shared by the core and the agent runtime."

  # Cents per 1,000 tokens {input, output}.
  @rates %{
    {"anthropic", "claude-fable-5"} => {0.5, 2.5},
    {"anthropic", "claude-opus-4-8"} => {1.5, 7.5},
    {"anthropic", "claude-sonnet-5"} => {0.3, 1.5},
    {"anthropic", "claude-haiku-4-5"} => {0.08, 0.4},
    {"openai", "gpt-5.6-sol"} => {1.5, 6.0},
    {"openai", "gpt-5.6-terra"} => {0.3, 1.2},
    {"openai", "gpt-5.6-luna"} => {0.015, 0.06}
  }
  @default_rate {0.3, 1.5}

  @doc "Cost in cents at a provider/model's rate; nil or unknown model falls back to the default rate."
  @spec cost_cents(String.t() | nil, String.t() | nil, non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def cost_cents(provider, model_id, input_tokens, output_tokens) do
    {in_rate, out_rate} = Map.get(@rates, {provider, model_id}, @default_rate)
    (input_tokens / 1000 * in_rate + output_tokens / 1000 * out_rate) |> Float.round(4) |> Float.ceil() |> trunc()
  end

  @doc "Rough token count: ~4 chars/token."
  @spec estimate_tokens(term()) :: non_neg_integer()
  def estimate_tokens(text) when is_binary(text), do: text |> String.length() |> div(4) |> max(0)
  def estimate_tokens(other), do: other |> inspect() |> estimate_tokens()
end
