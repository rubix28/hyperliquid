defmodule Hyperliquid.Api.Info.UserFills do
  @moduledoc """
  User's trade fills.

  Returns list of executed trades for a user.

  See: https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint#retrieve-a-users-fills

  ## Usage

      {:ok, fills} = UserFills.request("0x...")
      {:ok, pnl} = UserFills.total_pnl(fills)
  """

  use Hyperliquid.Api.Endpoint,
    type: :info,
    request_type: "userFills",
    params: [:user],
    optional_params: [:aggregateByTime],
    rate_limit_cost: 20,
    doc: "Retrieve a user's trade fills",
    returns: "UserFills struct with list of executed trades",
    storage: [
      postgres: [
        enabled: true,
        table: "fills",
        extract: :fills
      ],
      cache: [
        enabled: true,
        ttl: :timer.minutes(1),
        key_pattern: "user_fills:{{user}}"
      ]
    ]

  @type t :: %__MODULE__{
          fills: [Fill.t()]
        }

  @primary_key false
  embedded_schema do
    embeds_many :fills, Fill, primary_key: false do
      field(:coin, :string)
      field(:px, :string)
      field(:sz, :string)
      field(:side, :string)
      field(:time, :integer)
      field(:start_position, :string)
      field(:dir, :string)
      field(:closed_pnl, :string)
      field(:hash, :string)
      field(:oid, :integer)
      field(:crossed, :boolean)
      field(:fee, :string)
      field(:tid, :integer)
      field(:fee_token, :string)
    end
  end

  # ===================== Preprocessing =====================

  @doc false
  def preprocess(data) when is_list(data), do: %{fills: data}
  def preprocess(data), do: data

  # ===================== Changeset =====================

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(fills \\ %__MODULE__{}, attrs) do
    fills
    |> cast(attrs, [])
    |> cast_embed(:fills, with: &fill_changeset/2)
  end

  defp fill_changeset(fill, attrs) do
    attrs = normalize_attrs(attrs)

    fill
    |> cast(attrs, [
      :coin,
      :px,
      :sz,
      :side,
      :time,
      :start_position,
      :dir,
      :closed_pnl,
      :hash,
      :oid,
      :crossed,
      :fee,
      :tid,
      :fee_token
    ])
    |> validate_required([:coin, :px, :sz, :side, :time])
  end

  defp normalize_attrs(attrs) do
    %{
      coin: attrs["coin"] || attrs[:coin],
      px: attrs["px"] || attrs[:px],
      sz: attrs["sz"] || attrs[:sz],
      side: attrs["side"] || attrs[:side],
      time: attrs["time"] || attrs[:time],
      start_position: attrs["startPosition"] || attrs[:start_position],
      dir: attrs["dir"] || attrs[:dir],
      closed_pnl: attrs["closedPnl"] || attrs[:closed_pnl],
      hash: attrs["hash"] || attrs[:hash],
      oid: attrs["oid"] || attrs[:oid],
      crossed: attrs["crossed"] || attrs[:crossed],
      fee: attrs["fee"] || attrs[:fee],
      tid: attrs["tid"] || attrs[:tid],
      fee_token: attrs["feeToken"] || attrs[:fee_token]
    }
  end

  @spec by_coin(t(), String.t()) :: [map()]
  def by_coin(%__MODULE__{fills: fills}, coin), do: Enum.filter(fills, &(&1.coin == coin))

  @spec total_pnl(t()) :: {:ok, float()} | {:error, :parse_error}
  def total_pnl(%__MODULE__{fills: fills}) do
    try do
      total = fills |> Enum.map(&String.to_float(&1.closed_pnl)) |> Enum.sum()
      {:ok, total}
    rescue
      _ -> {:error, :parse_error}
    end
  end
end
