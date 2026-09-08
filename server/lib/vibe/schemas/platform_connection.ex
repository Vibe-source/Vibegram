defmodule Vibe.PlatformConnection do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w[pending active expired revoked error]
  @providers ~w[github microsoft_excel slack linear google_calendar]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "platform_connections" do
    field :provider, :string
    field :external_account_id, :string
    field :external_account_login, :string
    field :display_name, :string
    field :scopes, {:array, :string}, default: []
    field :status, :string, default: "active"
    field :access_token_encrypted, :string
    field :refresh_token_encrypted, :string
    field :token_expires_at, :utc_datetime
    field :metadata, :map, default: %{}
    field :last_used_at, :utc_datetime
    field :last_error, :string

    belongs_to :user, Vibe.Accounts.User
    has_many :grants, Vibe.ConnectionGrant, foreign_key: :connection_id

    timestamps()
  end

  def statuses, do: @statuses
  def providers, do: @providers

  def changeset(connection, attrs) do
    connection
    |> cast(attrs, [
      :user_id,
      :provider,
      :external_account_id,
      :external_account_login,
      :display_name,
      :scopes,
      :status,
      :access_token_encrypted,
      :refresh_token_encrypted,
      :token_expires_at,
      :metadata,
      :last_used_at,
      :last_error
    ])
    |> validate_required([:user_id, :provider, :status])
    |> validate_inclusion(:provider, @providers)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:user_id, :provider, :external_account_id],
      name: :platform_connections_user_provider_account_index
    )
  end
end
