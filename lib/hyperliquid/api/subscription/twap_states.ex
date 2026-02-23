defmodule Hyperliquid.Api.Subscription.TwapStates do
  @moduledoc """
  WebSocket subscription for TWAP execution states.

  See: https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/websocket/subscriptions
  """

  use Hyperliquid.Api.SubscriptionEndpoint,
    request_type: "twapStates",
    params: [:user, :dex],
    connection_type: :user_grouped,
    doc: "TWAP execution states - shares connection per user"

  @type t :: %__MODULE__{}

  @primary_key false
  embedded_schema do
    field(:user, :string)
    field(:dex, :string)
    field(:states, {:array, :map})
  end

  @spec build_request(map()) :: {:ok, map()} | {:error, Ecto.Changeset.t()}
  def build_request(params) do
    types = %{user: :string, dex: :string}

    changeset =
      {%{}, types}
      |> cast(params, Map.keys(types))
      |> validate_required([:user, :dex])
      |> validate_format(:user, ~r/^0x[0-9a-fA-F]{40}$/)

    if changeset.valid? do
      {:ok,
       %{
         type: "twapStates",
         user: get_change(changeset, :user),
         dex: get_change(changeset, :dex)
       }}
    else
      {:error, changeset}
    end
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(event \\ %__MODULE__{}, attrs) do
    event
    |> cast(attrs, [:user, :dex, :states])
  end
end
