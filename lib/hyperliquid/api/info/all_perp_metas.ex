defmodule Hyperliquid.Api.Info.AllPerpMetas do
  @moduledoc """
  Metadata for perpetual assets across all or a specific DEX.

  This is similar to the `meta` endpoint but allows querying metadata
  for a specific builder-deployed DEX.

  See: https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint/perpetuals
  """

  use Hyperliquid.Api.Endpoint,
    type: :info,
    request: %{type: "allPerpMetas"},
    rate_limit_cost: 2,
    doc: "Retrieve metadata for perpetual assets across all or a specific DEX",
    returns: "Universe of perp assets with margin tables and collateral token",
    storage: [
      postgres: [
        enabled: true,
        # NEW: Multi-table configuration
        tables: [
          # Perp assets table
          %{
            table: "perp_assets",
            extract: :universe,
            conflict_target: :name,
            on_conflict:
              {:replace,
               [
                 :sz_decimals,
                 :max_leverage,
                 :margin_table_id,
                 :only_isolated,
                 :is_delisted,
                 :margin_mode,
                 :growth_mode,
                 :last_growth_mode_change_time,
                 :updated_at
               ]}
          },
          # Margin tables
          %{
            table: "margin_tables",
            extract: :margin_tables,
            conflict_target: :id,
            on_conflict:
              {:replace,
               [
                 :description,
                 :margin_tiers,
                 :updated_at
               ]},
            transform: &__MODULE__.transform_margin_tables/1
          }
        ]
      ],
      cache: [enabled: false],
      context_params: []
    ]

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
      # Growth mode (for builder DEX assets)
      field(:growth_mode, :string)
      field(:last_growth_mode_change_time, :string)
    end

    embeds_many :margin_tables, MarginTable, primary_key: false do
      @moduledoc "Margin table with leverage tiers."

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
  # allPerpMetas returns an array of DEX metas - flatten all universes
  # Note: keys are already snake_cased by the HTTP transport layer
  def preprocess(data) when is_list(data) do
    # Flatten all universes from all DEXs into a single list
    all_universes =
      Enum.flat_map(data, fn dex_meta ->
        Map.get(dex_meta, "universe", [])
      end)

    # Aggregate all margin tables from all DEXs
    all_margin_tables =
      data
      |> Enum.flat_map(fn dex_meta ->
        margin_tables = Map.get(dex_meta, "margin_tables", [])
        normalize_margin_tables(margin_tables)
      end)
      |> Enum.uniq_by(fn table -> table["id"] end)

    # Get first DEX's collateral token (main DEX) - fallback to 0
    first_collateral =
      case data do
        [first | _] -> Map.get(first, "collateral_token", 0)
        _ -> 0
      end

    %{
      "universe" => all_universes,
      "margin_tables" => all_margin_tables,
      "collateral_token" => first_collateral
    }
  end

  def preprocess(data) when is_map(data) do
    # Single DEX meta (from "meta" endpoint with dex param)
    # Keys are already snake_cased by the HTTP transport layer
    margin_tables = Map.get(data, "margin_tables", [])
    normalized_tables = normalize_margin_tables(margin_tables)
    Map.put(data, "margin_tables", normalized_tables)
  end

  def preprocess(data), do: data

  defp normalize_margin_tables(margin_tables) do
    Enum.map(margin_tables, fn
      [id, table_data] when is_integer(id) and is_map(table_data) ->
        Map.put(table_data, "id", id)

      table when is_map(table) ->
        table
    end)
  end

  # ===================== Changesets =====================

  @doc """
  Creates a changeset for all perp metas data.

  ## Parameters
    - `all_perp_metas`: The all perp metas struct
    - `attrs`: Map of attributes to validate

  ## Returns
    - `Ecto.Changeset.t()`
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(all_perp_metas \\ %__MODULE__{}, attrs) do
    all_perp_metas
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
      :margin_mode,
      :growth_mode,
      :last_growth_mode_change_time
    ])
    |> validate_required([:sz_decimals, :name, :max_leverage, :margin_table_id])
    |> validate_number(:sz_decimals, greater_than_or_equal_to: 0)
    |> validate_number(:max_leverage, greater_than_or_equal_to: 1)
    |> validate_number(:margin_table_id, greater_than_or_equal_to: 0)
    |> validate_inclusion(:margin_mode, ["strictIsolated", "noCross", nil])
    |> validate_inclusion(:growth_mode, ["enabled", "disabled", nil])
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

  @doc """
  Find a universe entry by coin name.

  ## Parameters
    - `all_perp_metas`: The all perp metas struct
    - `name`: Coin name (e.g., "BTC", "ETH")

  ## Returns
    - `{:ok, Universe.t()}` if found
    - `{:error, :not_found}` if not found
  """
  @spec find_universe(t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def find_universe(%__MODULE__{universe: universe}, name) when is_binary(name) do
    case Enum.find(universe, &(&1.name == name)) do
      nil -> {:error, :not_found}
      entry -> {:ok, entry}
    end
  end

  @doc """
  Get all coin names in the universe.

  ## Parameters
    - `all_perp_metas`: The all perp metas struct

  ## Returns
    - List of coin names
  """
  @spec coin_names(t()) :: [String.t()]
  def coin_names(%__MODULE__{universe: universe}) do
    Enum.map(universe, & &1.name)
  end

  @doc """
  Get the margin table by ID.

  ## Parameters
    - `all_perp_metas`: The all perp metas struct
    - `id`: Margin table ID

  ## Returns
    - `{:ok, MarginTable.t()}` if found
    - `{:error, :not_found}` if not found
  """
  @spec get_margin_table(t(), integer()) :: {:ok, map()} | {:error, :not_found}
  def get_margin_table(%__MODULE__{margin_tables: tables}, id) when is_integer(id) do
    case Enum.find(tables, &(&1.id == id)) do
      nil -> {:error, :not_found}
      table -> {:ok, table}
    end
  end

  # ===================== Margin Table Storage =====================

  @doc """
  Store margin tables to the margin_tables table.

  This is separate from the main storage (perp_assets) since we need to
  store to two different tables from one API response.

  ## Parameters
    - `all_perp_metas`: The AllPerpMetas struct with margin_tables

  ## Returns
    - `{:ok, count}` - Number of margin tables stored/updated
    - `{:error, term()}` - Error details
  """
  @spec store_margin_tables(t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def store_margin_tables(%__MODULE__{margin_tables: tables}) do
    now = DateTime.utc_now()

    records =
      Enum.map(tables, fn table ->
        # Convert margin_tiers embedded structs to plain maps for JSONB storage
        margin_tiers =
          Enum.map(table.margin_tiers, fn tier ->
            Map.from_struct(tier) |> Map.drop([:__meta__])
          end)

        %{
          id: table.id,
          description: table.description,
          margin_tiers: margin_tiers,
          inserted_at: now,
          updated_at: now
        }
      end)

    repo = Hyperliquid.Repo

    if Code.ensure_loaded?(repo) do
      try do
        case apply(repo, :insert_all, [
               "margin_tables",
               records,
               [
                 on_conflict:
                   {:replace,
                    [
                      :description,
                      :margin_tiers,
                      :updated_at
                    ]},
                 conflict_target: :id,
                 returning: false
               ]
             ]) do
          {count, _} -> {:ok, count}
        end
      rescue
        error -> {:error, error}
      end
    else
      {:error, :repo_not_available}
    end
  end

  # ===================== Transform Functions =====================

  @doc """
  Transform margin tables for storage.

  Converts margin_tiers embedded list to JSONB-compatible format.
  This function is called automatically by the storage layer when using fetch/0.
  """
  def transform_margin_tables(tables) when is_list(tables) do
    Enum.map(tables, fn table ->
      # Convert margin_tiers embedded list to map list for JSONB
      margin_tiers =
        case Map.get(table, :margin_tiers) do
          nil ->
            nil

          tiers when is_list(tiers) ->
            Enum.map(tiers, fn tier ->
              case tier do
                %{__struct__: _} = struct ->
                  struct
                  |> Map.from_struct()
                  |> Map.drop([:__meta__])
                  |> Map.take([:lower_bound, :max_leverage])

                map when is_map(map) ->
                  Map.take(map, [:lower_bound, :max_leverage])
              end
            end)
        end

      # Convert table struct to map
      table
      |> (fn
            %{__struct__: _} = struct -> Map.from_struct(struct)
            map when is_map(map) -> map
          end).()
      |> Map.take([:id, :description, :margin_tiers])
      |> Map.put(:margin_tiers, margin_tiers)
    end)
  end
end
