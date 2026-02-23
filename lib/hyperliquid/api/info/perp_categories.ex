defmodule Hyperliquid.Api.Info.PerpCategories do
  @moduledoc """
  All perpetual coins with their assigned categories.

  See: https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint/perpetuals

  ## Usage

      {:ok, categories} = PerpCategories.request()
  """

  use Hyperliquid.Api.Endpoint,
    type: :info,
    request: %{type: "perpCategories"},
    rate_limit_cost: 1,
    raw_response: true,
    doc: "Retrieve all perpetual coins with their assigned categories",
    returns: "Map of perpetual coins to their categories"

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
  def preprocess(data) when is_list(data), do: %{data: %{categories: data}}
  def preprocess(data), do: %{data: data}

  # ===================== Changesets =====================

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(categories \\ %__MODULE__{}, attrs) do
    categories
    |> cast(attrs, [:data])
  end
end
