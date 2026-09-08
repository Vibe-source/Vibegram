defmodule Vibe.AccountsPrivacyTest do
  use ExUnit.Case, async: true

  alias Vibe.Accounts
  alias Vibe.Accounts.User

  test "nobody is hidden from others and from an anonymous viewer, not from self" do
    owner = %User{id: Ecto.UUID.generate(), privacy_bio: "nobody"}
    other = %User{id: Ecto.UUID.generate()}

    assert Accounts.viewer_can_see?(owner, owner, :privacy_bio)
    refute Accounts.viewer_can_see?(owner, other, :privacy_bio)
    refute Accounts.viewer_can_see?(owner, nil, :privacy_bio)
  end

  test "everybody is visible without a DM" do
    owner = %User{id: Ecto.UUID.generate(), privacy_bio: "everybody"}
    other = %User{id: Ecto.UUID.generate()}

    assert Accounts.viewer_can_see?(owner, other, :privacy_bio)
    assert Accounts.viewer_can_see?(owner, nil, :privacy_bio)
  end
end
