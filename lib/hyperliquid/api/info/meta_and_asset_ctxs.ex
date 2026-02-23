defmodule Hyperliquid.Api.Info.MetaAndAssetCtxs do
  @moduledoc """
  Metadata and context for perpetual assets.

  This endpoint returns a tuple of [Meta, AssetCtxs[]] in the TypeScript SDK,
  represented here as a schema with two fields: `meta` and `asset_ctxs`.

  See: https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint/perpetuals#retrieve-perpetuals-asset-contexts-includes-mark-price-current-funding-open-interest-etc
  """

  use Hyperliquid.Api.Endpoint,
    type: :info,
    request_type: "metaAndAssetCtxs",
    optional_params: [:dex],
    rate_limit_cost: 2,
    doc: "Retrieve perpetuals metadata and asset contexts",
    returns: "Metadata and context for all perpetual assets"

  @type t :: %__MODULE__{
          meta: Meta.t(),
          asset_ctxs: [AssetCtx.t()]
        }

  @primary_key false
  embedded_schema do
    embeds_one :meta, Meta, primary_key: false do
      @moduledoc "Metadata for perpetual assets."

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

    embeds_many :asset_ctxs, AssetCtx, primary_key: false do
      @moduledoc "Context for a specific perpetual asset."

      field(:prev_day_px, :string)
      field(:day_ntl_vlm, :string)
      field(:mark_px, :string)
      field(:mid_px, :string)
      field(:funding, :string)
      field(:open_interest, :string)
      field(:premium, :string)
      field(:oracle_px, :string)
      field(:impact_pxs, {:array, :string})
      field(:day_base_vlm, :string)
    end
  end

  # ===================== Preprocessing =====================

  @doc false
  def preprocess([meta, asset_ctxs]) when is_map(meta) and is_list(asset_ctxs) do
    # Normalize margin_tables from [id, %{...}] tuples to maps with id
    normalized_meta = normalize_margin_tables(meta)
    %{meta: normalized_meta, asset_ctxs: asset_ctxs}
  end

  def preprocess(data), do: data

  defp normalize_margin_tables(meta) do
    {key, margin_tables} =
      cond do
        Map.has_key?(meta, "marginTables") ->
          {"marginTables", Map.get(meta, "marginTables", [])}

        Map.has_key?(meta, "margin_tables") ->
          {"margin_tables", Map.get(meta, "margin_tables", [])}

        true ->
          {"margin_tables", []}
      end

    normalized =
      Enum.map(margin_tables, fn
        [id, table_data] when is_integer(id) and is_map(table_data) ->
          Map.put(table_data, "id", id)

        table when is_map(table) ->
          table
      end)

    Map.put(meta, key, normalized)
  end

  # ===================== Changesets =====================

  @doc """
  Creates a changeset for meta and asset contexts data.

  ## Parameters
    - `meta_and_asset_ctxs`: The meta and asset contexts struct
    - `attrs`: Map of attributes to validate

  ## Returns
    - `Ecto.Changeset.t()`
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(meta_and_asset_ctxs \\ %__MODULE__{}, attrs) do
    meta_and_asset_ctxs
    |> cast(attrs, [])
    |> cast_embed(:meta, with: &meta_changeset/2)
    |> cast_embed(:asset_ctxs, with: &asset_ctx_changeset/2)
  end

  defp meta_changeset(meta, attrs) do
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

  defp asset_ctx_changeset(asset_ctx, attrs) do
    asset_ctx
    |> cast(attrs, [
      :prev_day_px,
      :day_ntl_vlm,
      :mark_px,
      :mid_px,
      :funding,
      :open_interest,
      :premium,
      :oracle_px,
      :impact_pxs,
      :day_base_vlm
    ])
    |> validate_required([
      :prev_day_px,
      :day_ntl_vlm,
      :mark_px,
      :funding,
      :open_interest,
      :oracle_px,
      :day_base_vlm
    ])
  end
end
