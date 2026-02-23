defmodule Hyperliquid.Api.Info.PerpDexStatus do
  @moduledoc """
  Overall status metrics for a builder-deployed perpetual market.

  See: https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint/perpetuals

  ## Usage

      {:ok, status} = PerpDexStatus.request(dex: "some_dex")
  """

  use Hyperliquid.Api.Endpoint,
    type: :info,
    request_type: "perpDexStatus",
    optional_params: [:dex],
    rate_limit_cost: 1,
    doc: "Retrieve status metrics for a builder-deployed perpetual market",
    returns: "Status metrics for the perpetual DEX",
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
  def changeset(status \\ %__MODULE__{}, attrs) do
    status
    |> cast(attrs, [:data])
  end
end
