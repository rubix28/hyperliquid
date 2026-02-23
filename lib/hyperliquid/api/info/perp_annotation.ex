defmodule Hyperliquid.Api.Info.PerpAnnotation do
  @moduledoc """
  Category and description annotation for a specific perpetual.

  See: https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint/perpetuals

  ## Usage

      {:ok, annotation} = PerpAnnotation.request("BTC")
  """

  use Hyperliquid.Api.Endpoint,
    type: :info,
    request_type: "perpAnnotation",
    params: [:coin],
    rate_limit_cost: 1,
    doc: "Retrieve category and description annotation for a perpetual",
    returns: "Annotation data with category and description",
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
  def changeset(annotation \\ %__MODULE__{}, attrs) do
    annotation
    |> cast(attrs, [:data])
  end
end
