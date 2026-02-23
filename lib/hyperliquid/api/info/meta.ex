defmodule Hyperliquid.Api.Info.Meta do
  @moduledoc """
  Metadata for perpetual assets.

  See: https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint/perpetuals#retrieve-perpetuals-metadata-universe-and-margin-tables

  ## Usage

      {:ok, meta} = Meta.request()
      {:ok, meta} = Meta.request(dex: "some_dex")
  """

  use Hyperliquid.Api.Endpoint,
    type: :info,
    request_type: "meta",
    optional_params: [:dex],
    rate_limit_cost: 20,
    doc: "Retrieve perpetuals metadata (universe and margin tables)",
    returns: "Meta struct with universe, margin tables, and collateral token"

  @type t :: %__MODULE__{
          universe: [Universe.t()],
          margin_tables: [MarginTable.t()],
          collateral_token: non_neg_integer()
        }

  @primary_key false
  embedded_schema do
    embeds_many :universe, Universe, primary_key: false do
      @moduledoc "Trading universe parameters for perpetual asset."

      field(:sz_decimals, :integer)
      field(:name, :string)
      field(:max_leverage, :integer)
      field(:margin_table_id, :integer)
      field(:only_isolated, :boolean, default: false)
      field(:is_delisted, :boolean, default: false)
      field(:margin_mode, :string)
    end

    embeds_many :margin_tables, MarginTable, primary_key: false do
      @moduledoc "Tuple of margin table ID and its details."

      field(:id, :integer)
      field(:description, :string)

      embeds_many :margin_tiers, MarginTier, primary_key: false do
        @moduledoc "Individual tier in a margin requirements table."

        field(:lower_bound, :string)
        field(:max_leverage, :integer)
      end
    end

    field(:collateral_token, :integer)
  end

  # ===================== Preprocessing =====================

  @doc false
  def preprocess(%{"margin_tables" => tables} = data) when is_list(tables) do
    transformed_tables =
      Enum.map(tables, fn
        [id, table_data] when is_integer(id) and is_map(table_data) ->
          Map.put(table_data, "id", id)

        other ->
          other
      end)

    Map.put(data, "margin_tables", transformed_tables)
  end

  def preprocess(data), do: data

  # ===================== Changeset =====================

  @doc """
  Creates a changeset for meta data.

  ## Parameters
    - `meta`: The meta struct
    - `attrs`: Map of attributes to validate

  ## Returns
    - `Ecto.Changeset.t()`
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(meta \\ %__MODULE__{}, attrs) do
    meta
    |> cast(attrs, [:collateral_token])
    |> cast_embed(:universe, with: &universe_changeset/2)
    |> cast_embed(:margin_tables, with: &margin_table_changeset/2)
    |> validate_required([:collateral_token])
    |> validate_number(:collateral_token, greater_than_or_equal_to: 0)
  end

  defp universe_changeset(universe, attrs) do
    universe
    |> cast(attrs, [
      :sz_decimals,
      :name,
      :max_leverage,
      :margin_table_id,
      :only_isolated,
      :is_delisted,
      :margin_mode
    ])
    |> validate_required([:sz_decimals, :name, :max_leverage, :margin_table_id])
    |> validate_number(:sz_decimals, greater_than_or_equal_to: 0)
    |> validate_number(:max_leverage, greater_than_or_equal_to: 1)
    |> validate_number(:margin_table_id, greater_than_or_equal_to: 0)
    |> validate_inclusion(:margin_mode, ["strictIsolated", "noCross", nil])
  end

  defp margin_table_changeset(margin_table, attrs) do
    margin_table
    |> cast(attrs, [:id, :description])
    |> cast_embed(:margin_tiers, with: &margin_tier_changeset/2)
    |> validate_required([:id])
    |> validate_number(:id, greater_than_or_equal_to: 0)
  end

  defp margin_tier_changeset(margin_tier, attrs) do
    margin_tier
    |> cast(attrs, [:lower_bound, :max_leverage])
    |> validate_required([:lower_bound, :max_leverage])
    |> validate_number(:max_leverage, greater_than_or_equal_to: 1)
  end
end
