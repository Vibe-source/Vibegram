defmodule VibeContracts.WebhookSignatureTest do
  use ExUnit.Case, async: true
  alias VibeContracts.WebhookSignature

  @secret "wh-secret"
  @body ~s({"event":"ping"})

  test "sign/3 then verify/4 round-trips" do
    header = WebhookSignature.sign(@secret, @body, 1000)
    assert "t=1000,v1=" <> _sig = header
    assert :ok = WebhookSignature.verify(@secret, @body, header, now: 1000)
  end

  test "a tampered body fails verification" do
    header = WebhookSignature.sign(@secret, @body, 1000)

    assert {:error, :bad_signature} =
             WebhookSignature.verify(@secret, @body <> "x", header, now: 1000)
  end

  test "the wrong secret fails verification" do
    header = WebhookSignature.sign(@secret, @body, 1000)

    assert {:error, :bad_signature} =
             WebhookSignature.verify("wrong-secret", @body, header, now: 1000)
  end

  test "a stale timestamp is rejected outside tolerance, accepted at the edge" do
    header = WebhookSignature.sign(@secret, @body, 1000)
    assert {:error, :stale_timestamp} = WebhookSignature.verify(@secret, @body, header, now: 1301)
    assert :ok = WebhookSignature.verify(@secret, @body, header, now: 1300)
  end

  test "a custom tolerance_seconds is honored" do
    header = WebhookSignature.sign(@secret, @body, 1000)

    assert {:error, :stale_timestamp} =
             WebhookSignature.verify(@secret, @body, header, now: 1010, tolerance_seconds: 5)

    assert :ok = WebhookSignature.verify(@secret, @body, header, now: 1010, tolerance_seconds: 20)
  end

  test "a header with multiple v1= entries verifies against any matching secret (rotation)" do
    old_secret = "old-secret"
    new_secret = "new-secret"

    old_header = WebhookSignature.sign(old_secret, @body, 1000)
    "t=1000,v1=" <> old_sig = old_header
    new_header = WebhookSignature.sign(new_secret, @body, 1000)
    "t=1000,v1=" <> new_sig = new_header

    rotated_header = "t=1000,v1=#{old_sig},v1=#{new_sig}"

    assert :ok = WebhookSignature.verify(old_secret, @body, rotated_header, now: 1000)
    assert :ok = WebhookSignature.verify(new_secret, @body, rotated_header, now: 1000)

    assert {:error, :bad_signature} =
             WebhookSignature.verify("neither", @body, rotated_header, now: 1000)
  end

  test "a malformed or missing header is rejected" do
    assert {:error, :malformed_header} =
             WebhookSignature.verify(@secret, @body, "garbage", now: 1000)

    assert {:error, :malformed_header} =
             WebhookSignature.verify(@secret, @body, "t=1000", now: 1000)

    assert {:error, :missing_header} = WebhookSignature.verify(@secret, @body, nil, now: 1000)
  end
end
