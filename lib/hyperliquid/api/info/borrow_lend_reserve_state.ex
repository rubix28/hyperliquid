defmodule Hyperliquid.Api.Info.BorrowLendReserveState do
  @moduledoc """
  Borrow/lend reserve state for a specific token.

  Returns reserve statistics including rates, utilization, LTV, and total supply/borrow
  for a given token in the borrow/lend protocol.

  See: https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint

  ## Usage

      {:ok, reserve} = BorrowLendReserveState.request(0)
  """

  use Hyperliquid.Api.Endpoint,
    type: :info,
    request_type: "borrowLendReserveState",
    params: [:token],
    rate_limit_cost: 20,
    doc: "Retrieve borrow/lend reserve state for a token",
    returns: "Reserve statistics including rates, utilization, and supply/borrow data",
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
  def preprocess(data) when is_map(data), do: %{data: data}
  def preprocess(data), do: %{data: data}

  # ===================== Changesets =====================

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(state \\ %__MODULE__{}, attrs) do
    state
    |> cast(attrs, [:data])
  end
end
