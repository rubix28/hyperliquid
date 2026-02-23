defmodule Hyperliquid.Api.Info.OpenOrders do
  @moduledoc """
  User's open orders.

  Returns list of currently open orders.

  See: https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint#retrieve-a-users-open-orders

  ## Usage

      {:ok, orders} = OpenOrders.request("0x...")
      btc_orders = OpenOrders.by_coin(orders, "BTC")
  """

  use Hyperliquid.Api.Endpoint,
    type: :info,
    request_type: "openOrders",
    params: [:user],
    optional_params: [:dex],
    rate_limit_cost: 20,
    doc: "Retrieve a user's open orders",
    returns: "OpenOrders struct with list of open orders",
    storage: [
      postgres: [
        enabled: true,
        table: "orders",
        extract: :orders
      ],
      cache: [
        enabled: true,
        ttl: :timer.seconds(10),
        key_pattern: "open_orders:{{user}}"
      ]
    ]

  @type t :: %__MODULE__{
          orders: [Order.t()]
        }

  @primary_key false
  embedded_schema do
    embeds_many :orders, Order, primary_key: false do
      @moduledoc "Open order."

      field(:coin, :string)
      field(:side, :string)
      field(:limit_px, :string)
      field(:sz, :string)
      field(:oid, :integer)
      field(:timestamp, :integer)
      field(:orig_sz, :string)
    end
  end

  # ===================== Preprocessing =====================

  @doc false
  def preprocess(data) when is_list(data), do: %{orders: data}
  def preprocess(data), do: data

  # ===================== Changeset =====================

  @doc """
  Creates a changeset for open orders data.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(orders \\ %__MODULE__{}, attrs) do
    orders
    |> cast(attrs, [])
    |> cast_embed(:orders, with: &order_changeset/2)
  end

  defp order_changeset(order, attrs) do
    order
    |> cast(attrs, [:coin, :side, :limit_px, :sz, :oid, :timestamp, :orig_sz])
    |> validate_required([:coin, :side, :limit_px, :sz, :oid, :timestamp])
  end

  # ===================== Helpers =====================

  @doc """
  Get orders by coin.
  """
  @spec by_coin(t(), String.t()) :: [map()]
  def by_coin(%__MODULE__{orders: orders}, coin) do
    Enum.filter(orders, &(&1.coin == coin))
  end

  @doc """
  Get buy orders.
  """
  @spec buys(t()) :: [map()]
  def buys(%__MODULE__{orders: orders}) do
    Enum.filter(orders, &(&1.side == "B"))
  end

  @doc """
  Get sell orders.
  """
  @spec sells(t()) :: [map()]
  def sells(%__MODULE__{orders: orders}) do
    Enum.filter(orders, &(&1.side == "A"))
  end

  @doc """
  Find by OID.
  """
  @spec find_by_oid(t(), integer()) :: {:ok, map()} | {:error, :not_found}
  def find_by_oid(%__MODULE__{orders: orders}, oid) do
    case Enum.find(orders, &(&1.oid == oid)) do
      nil -> {:error, :not_found}
      order -> {:ok, order}
    end
  end

  @doc """
  Get count.
  """
  @spec count(t()) :: non_neg_integer()
  def count(%__MODULE__{orders: orders}), do: length(orders)
end
