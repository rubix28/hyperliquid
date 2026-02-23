defmodule Hyperliquid.Api.Info.ClearinghouseState do
  @moduledoc """
  Account summary for perpetual trading.

  See: https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint/perpetuals#retrieve-users-perpetuals-account-summary

  ## Usage

      {:ok, state} = ClearinghouseState.request("0x1234...")
  """

  use Hyperliquid.Api.Endpoint,
    type: :info,
    request_type: "clearinghouseState",
    params: [:user],
    optional_params: [:dex],
    rate_limit_cost: 2,
    doc: "Retrieve a user's perpetuals account summary",
    returns: "Clearinghouse state with margin summary and positions",
    # Request param `user` is merged into storage data by fetch/1
    storage: [
      postgres: [
        enabled: true,
        table: "clearinghouse_states"
      ],
      cache: [
        enabled: true,
        ttl: :timer.seconds(30),
        key_pattern: "clearinghouse:{{user}}"
      ]
    ]

  @type t :: %__MODULE__{
          margin_summary: MarginSummary.t(),
          cross_margin_summary: MarginSummary.t(),
          cross_maintenance_margin_used: String.t(),
          withdrawable: String.t(),
          asset_positions: [AssetPosition.t()],
          time: non_neg_integer()
        }

  @primary_key false
  embedded_schema do
    embeds_one :margin_summary, MarginSummary do
      @moduledoc "Margin summary details."

      field(:account_value, :string)
      field(:total_ntl_pos, :string)
      field(:total_raw_usd, :string)
      field(:total_margin_used, :string)
    end

    embeds_one :cross_margin_summary, CrossMarginSummary do
      @moduledoc "Cross-margin summary details."

      field(:account_value, :string)
      field(:total_ntl_pos, :string)
      field(:total_raw_usd, :string)
      field(:total_margin_used, :string)
    end

    field(:cross_maintenance_margin_used, :string)
    field(:withdrawable, :string)

    embeds_many :asset_positions, AssetPosition do
      @moduledoc "Position for a specific asset."

      field(:type, :string)

      embeds_one :position, Position do
        @moduledoc "Position details."

        field(:coin, :string)
        field(:szi, :string)
        field(:entry_px, :string)
        field(:position_value, :string)
        field(:unrealized_pnl, :string)
        field(:return_on_equity, :string)
        field(:liquidation_px, :string)
        field(:margin_used, :string)
        field(:max_leverage, :integer)

        # Leverage is a variant - using map for flexibility
        field(:leverage, :map)

        embeds_one :cum_funding, CumFunding do
          @moduledoc "Cumulative funding details."

          field(:all_time, :string)
          field(:since_open, :string)
          field(:since_change, :string)
        end
      end
    end

    field(:time, :integer)
  end

  # ===================== Changeset =====================

  @doc """
  Creates a changeset for clearinghouse state data.

  ## Parameters
    - `clearinghouse_state`: The clearinghouse state struct
    - `attrs`: Map of attributes to validate

  ## Returns
    - `Ecto.Changeset.t()`
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(clearinghouse_state \\ %__MODULE__{}, attrs) do
    clearinghouse_state
    |> cast(attrs, [:cross_maintenance_margin_used, :withdrawable, :time])
    |> cast_embed(:margin_summary, with: &margin_summary_changeset/2)
    |> cast_embed(:cross_margin_summary, with: &margin_summary_changeset/2)
    |> cast_embed(:asset_positions, with: &asset_position_changeset/2)
    |> validate_required([:cross_maintenance_margin_used, :withdrawable, :time])
    |> validate_number(:time, greater_than_or_equal_to: 0)
  end

  defp margin_summary_changeset(margin_summary, attrs) do
    margin_summary
    |> cast(attrs, [:account_value, :total_ntl_pos, :total_raw_usd, :total_margin_used])
    |> validate_required([:account_value, :total_ntl_pos, :total_raw_usd, :total_margin_used])
  end

  defp asset_position_changeset(asset_position, attrs) do
    asset_position
    |> cast(attrs, [:type])
    |> cast_embed(:position, with: &position_changeset/2)
    |> validate_required([:type])
    |> validate_inclusion(:type, ["oneWay"])
  end

  defp position_changeset(position, attrs) do
    position
    |> cast(attrs, [
      :coin,
      :szi,
      :leverage,
      :entry_px,
      :position_value,
      :unrealized_pnl,
      :return_on_equity,
      :liquidation_px,
      :margin_used,
      :max_leverage
    ])
    |> cast_embed(:cum_funding, with: &cum_funding_changeset/2)
    |> validate_required([
      :coin,
      :szi,
      :leverage,
      :entry_px,
      :position_value,
      :unrealized_pnl,
      :return_on_equity,
      :margin_used,
      :max_leverage
    ])
    |> validate_number(:max_leverage, greater_than_or_equal_to: 1)
    |> validate_leverage()
  end

  defp cum_funding_changeset(cum_funding, attrs) do
    cum_funding
    |> cast(attrs, [:all_time, :since_open, :since_change])
    |> validate_required([:all_time, :since_open, :since_change])
  end

  # Validates the leverage variant structure
  # Keys may be camelCase (raw API) or snake_case (after normalization)
  defp validate_leverage(changeset) do
    validate_change(changeset, :leverage, fn :leverage, leverage ->
      type = leverage["type"]
      value = leverage["value"]

      has_raw_usd =
        Map.has_key?(leverage, "rawUsd") or Map.has_key?(leverage, "raw_usd")

      cond do
        type == "isolated" and is_integer(value) and value >= 1 and has_raw_usd ->
          []

        type == "cross" and is_integer(value) and value >= 1 ->
          []

        true ->
          [leverage: "must be valid isolated or cross leverage structure"]
      end
    end)
  end

  # ===================== Storage Field Mapping =====================

  # Override DSL-generated function to convert struct to camelCase JSONB format
  # This matches the WebSocket subscription format for consistency
  def extract_postgres_fields(data) do
    alias Hyperliquid.Utils

    %{
      user: get_field_value(data, :user),
      # Default empty string for dex
      dex: "",
      margin_summary: Utils.to_camel_case_map(get_field_value(data, :margin_summary)),
      cross_margin_summary: Utils.to_camel_case_map(get_field_value(data, :cross_margin_summary)),
      withdrawable: get_field_value(data, :withdrawable),
      asset_positions:
        (get_field_value(data, :asset_positions) || [])
        |> Enum.map(&Utils.to_camel_case_map/1)
    }
  end

  # Get field value from struct or map
  defp get_field_value(%_{} = struct, field), do: Map.get(struct, field)
  defp get_field_value(map, field) when is_map(map), do: Map.get(map, field)
  defp get_field_value(_, _), do: nil
end
