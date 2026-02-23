defmodule Hyperliquid.Api.Info.ApprovedBuilders do
  @moduledoc """
  List of builder addresses approved by a user for MEV operations.

  See: https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint

  ## Usage

      {:ok, builders} = ApprovedBuilders.request("0x...")
  """

  use Hyperliquid.Api.Endpoint,
    type: :info,
    request_type: "approvedBuilders",
    params: [:user],
    rate_limit_cost: 1,
    doc: "Retrieve approved builder addresses for a user",
    returns: "List of approved builder addresses with fee rates",
    raw_response: true

  @type t :: %__MODULE__{
          data: list() | map()
        }

  @primary_key false
  embedded_schema do
    field(:data, :map)
  end

  # ===================== Preprocessing =====================

  @doc false
  def preprocess(data) when is_list(data), do: %{data: %{builders: data}}
  def preprocess(data) when is_map(data), do: %{data: data}
  def preprocess(data), do: %{data: data}

  # ===================== Changesets =====================

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(builders \\ %__MODULE__{}, attrs) do
    builders
    |> cast(attrs, [:data])
  end
end
