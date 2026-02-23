defmodule Hyperliquid.Api.Info.BorrowLendUserState do
  @moduledoc """
  User's borrow/lend positions and account health.

  Returns the user's current borrow and lending positions, including basis values
  and account health metrics.

  See: https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint

  ## Usage

      {:ok, state} = BorrowLendUserState.request("0x...")
  """

  use Hyperliquid.Api.Endpoint,
    type: :info,
    request_type: "borrowLendUserState",
    params: [:user],
    rate_limit_cost: 20,
    doc: "Retrieve user's borrow/lend positions and account health",
    returns: "User's borrow/lend state including positions and health metrics",
    raw_response: true

  @type t :: %__MODULE__{
          data: map()
        }

  @primary_key false
  embedded_schema do
    field(:data, :map)
  end

  # ===================== Preprocessing =====================

  @doc false
  def preprocess(data) when is_list(data), do: %{data: %{positions: data}}
  def preprocess(data) when is_map(data), do: %{data: data}
  def preprocess(data), do: %{data: data}

  # ===================== Changesets =====================

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(state \\ %__MODULE__{}, attrs) do
    state
    |> cast(attrs, [:data])
  end
end
