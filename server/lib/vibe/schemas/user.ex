defmodule Vibe.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  schema "users" do
    field :username, :string
    field :password_hash, :string
    field :public_key, :string
    field :identity_key, :string
    field :encrypted_private_key, :string
    field :device_id, :string
    field :login_token, :string
    field :token_expires_at, :utc_datetime  # SECURITY: Token expiration
    field :token_issued_at, :utc_datetime  # SECURITY: absolute lifetime anchor (sliding expiry cannot move this)
    field :secure_id, :string
    field :profile_image, :string
    field :push_token, :string
    field :is_agent, :boolean, default: false
    field :is_online, :boolean, default: false, virtual: true
    field :last_seen, :utc_datetime
    field :phone_number, :string
    field :name, :string

    field :signed_pre_key_id, :integer
    field :signed_pre_key, :string
    field :signed_pre_key_signature, :string
    field :supports_advanced, :boolean, default: false

    field :tier, :string, default: "free"
    field :referral_code, :string
    field :referral_count, :integer, default: 0
    field :business_profile_enabled, :boolean, default: false
    field :auto_reply_enabled, :boolean, default: false
    field :auto_reply_message, :string
    field :business_hours_start, :time
    field :business_hours_end, :time

    field :show_last_seen, :boolean, default: true
    field :show_online_status, :boolean, default: true
    field :bio, :string
    field :auto_delete_timer, :integer, default: 0
    field :privacy_forward, :string, default: "everybody"
    field :privacy_calls, :string, default: "everybody"
    field :privacy_phone_number, :string, default: "everybody"
    field :privacy_profile_photos, :string, default: "everybody"
    field :privacy_bio, :string, default: "everybody"
    field :privacy_gifts, :string, default: "everybody"
    field :privacy_birthday, :string, default: "everybody"
    field :privacy_saved_music, :string, default: "everybody"
    field :date_of_birth, :date

    has_many :badges, Vibe.Badges.Badge
    has_one :subscription, Vibe.Subscriptions.UserSubscription


    timestamps()
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [
      :id, :username, :name, :password_hash, :public_key, :identity_key,
      :encrypted_private_key, :device_id, :login_token, :token_expires_at, :token_issued_at, :secure_id,
      :profile_image, :push_token, :is_agent, :signed_pre_key_id, :signed_pre_key, :signed_pre_key_signature,
      :supports_advanced, :phone_number, :tier, :referral_code, :referral_count,
      :business_profile_enabled, :auto_reply_enabled, :auto_reply_message,
      :last_seen,
      :business_hours_start, :business_hours_end, :show_last_seen, :show_online_status,
      :bio, :auto_delete_timer, :privacy_forward, :privacy_calls,
      :privacy_phone_number, :privacy_profile_photos, :privacy_bio, :privacy_gifts, :privacy_birthday,
      :privacy_saved_music, :date_of_birth
    ])
    |> validate_required([:username, :password_hash, :public_key, :device_id])
    |> validate_length(:username, min: 3, max: 30)
    |> validate_format(:username, ~r/^[a-zA-Z0-9_]+$/, message: "can only contain letters, numbers, and underscores")
    |> validate_inclusion(:tier, ["free", "bronze", "silver", "gold"])
    |> validate_inclusion(:privacy_forward, ["everybody", "contacts", "nobody"])
    |> validate_inclusion(:privacy_calls, ["everybody", "contacts", "nobody"])
    |> validate_inclusion(:privacy_phone_number, ["everybody", "contacts", "nobody"])
    |> validate_inclusion(:privacy_profile_photos, ["everybody", "contacts", "nobody"])
    |> validate_inclusion(:privacy_bio, ["everybody", "contacts", "nobody"])
    |> validate_inclusion(:privacy_gifts, ["everybody", "contacts", "nobody"])
    |> validate_inclusion(:privacy_birthday, ["everybody", "contacts", "nobody"])
    |> validate_inclusion(:privacy_saved_music, ["everybody", "contacts", "nobody"])
    |> unique_constraint(:username)
    |> unique_constraint(:phone_number)
    |> unique_constraint(:referral_code)
  end

  @profile_fields [
    :name,
    :bio,
    :profile_image,
    :show_last_seen,
    :show_online_status,
    :auto_delete_timer,
    :privacy_forward,
    :privacy_calls,
    :privacy_phone_number,
    :privacy_profile_photos,
    :privacy_bio,
    :privacy_gifts,
    :privacy_birthday,
    :privacy_saved_music,
    :date_of_birth,
    :business_profile_enabled,
    :auto_reply_enabled,
    :auto_reply_message,
    :business_hours_start,
    :business_hours_end
  ]

  # SECURITY:
  def profile_changeset(user, attrs) do
    user
    |> cast(attrs, @profile_fields)
    |> validate_inclusion(:privacy_forward, ["everybody", "contacts", "nobody"])
    |> validate_inclusion(:privacy_calls, ["everybody", "contacts", "nobody"])
    |> validate_inclusion(:privacy_phone_number, ["everybody", "contacts", "nobody"])
    |> validate_inclusion(:privacy_profile_photos, ["everybody", "contacts", "nobody"])
    |> validate_inclusion(:privacy_bio, ["everybody", "contacts", "nobody"])
    |> validate_inclusion(:privacy_gifts, ["everybody", "contacts", "nobody"])
    |> validate_inclusion(:privacy_birthday, ["everybody", "contacts", "nobody"])
    |> validate_inclusion(:privacy_saved_music, ["everybody", "contacts", "nobody"])
  end
end
