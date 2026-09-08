defmodule Vibe.MeshAssemblerTest do
  use ExUnit.Case, async: false

  alias Vibe.MeshAssembler

  defp unique_set_id, do: "set-#{System.unique_integer([:positive])}"

  test "rejects unbounded threshold quickly" do
    assert {:error, :invalid_threshold} =
             MeshAssembler.submit_fragment(%{
               "set_id" => unique_set_id(),
               "threshold" => 10_000,
               "share_index" => 1,
               "total_shares" => 10_000,
               "payload_len" => 4,
               "share_data" => [1, 2, 3, 4]
             })
  end

  test "rejects unbounded total_shares quickly" do
    assert {:error, :invalid_total_shares} =
             MeshAssembler.submit_fragment(%{
               "set_id" => unique_set_id(),
               "threshold" => 2,
               "share_index" => 1,
               "total_shares" => 100_000,
               "payload_len" => 4,
               "share_data" => [1, 2, 3, 4]
             })
  end

  test "rejects invalid share_index quickly" do
    assert {:error, :invalid_share_index} =
             MeshAssembler.submit_fragment(%{
               "set_id" => unique_set_id(),
               "threshold" => 2,
               "share_index" => 0,
               "total_shares" => 3,
               "payload_len" => 4,
               "share_data" => [1, 2, 3, 4]
             })

    assert {:error, :invalid_share_index} =
             MeshAssembler.submit_fragment(%{
               "set_id" => unique_set_id(),
               "threshold" => 2,
               "share_index" => 99,
               "total_shares" => 3,
               "payload_len" => 4,
               "share_data" => [1, 2, 3, 4]
             })
  end

  test "rejects oversized payload_len quickly" do
    assert {:error, :invalid_payload_len} =
             MeshAssembler.submit_fragment(%{
               "set_id" => unique_set_id(),
               "threshold" => 2,
               "share_index" => 1,
               "total_shares" => 3,
               "payload_len" => 1_000_000,
               "share_data" => [1, 2, 3, 4]
             })
  end

  test "rejects oversized share_data quickly" do
    huge = List.duplicate(1, 70_000)

    assert {:error, :invalid_share_data} =
             MeshAssembler.submit_fragment(%{
               "set_id" => unique_set_id(),
               "threshold" => 2,
               "share_index" => 1,
               "total_shares" => 3,
               "payload_len" => nil,
               "share_data" => huge
             })
  end

  test "rejects missing required fields" do
    assert {:error, :invalid_fragment} =
             MeshAssembler.submit_fragment(%{"set_id" => unique_set_id()})
  end

  test "accepts a well-bounded fragment as pending when below threshold" do
    assert :pending =
             MeshAssembler.submit_fragment(%{
               "set_id" => unique_set_id(),
               "threshold" => 2,
               "share_index" => 1,
               "total_shares" => 3,
               "payload_len" => 4,
               "share_data" => [10, 20, 30, 40]
             })
  end
end
