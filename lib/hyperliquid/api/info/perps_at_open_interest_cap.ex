defmodule Hyperliquid.Api.Info.PerpsAtOpenInterestCap do
  @moduledoc """
  List of perpetuals currently at their open interest cap.

  Returns an array of coin symbols that have reached their maximum open interest.

  See: https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint/perpetuals
  """

  use Hyperliquid.Api.Endpoint,
    type: :info,
    request_type: "perpsAtOpenInterestCap",
    params: [],
    optional_params: [:dex],
    rate_limit_cost: 1,
    doc: "Retrieve perpetuals at open interest cap",
    returns: "Array of coin symbols at their maximum open interest"

  @type t :: %__MODULE__{
          coins: [String.t()]
        }

  @primary_key false
  embedded_schema do
    # List of coin symbols at their open interest cap
    # Example: ["BTC", "ETH", "SOL"]
    field(:coins, {:array, :string})
  end

  # ===================== Preprocessing =====================

  @doc false
  def preprocess(data) when is_list(data) do
    %{coins: data}
  end

  def preprocess(data), do: data

  # ===================== Changesets =====================

  @doc """
  Creates a changeset for perps at open interest cap data.

  ## Parameters
    - `perps`: The perps struct
    - `attrs`: Map with coins key

  ## Returns
    - `Ecto.Changeset.t()`

  ## Example
      iex> changeset(%PerpsAtOpenInterestCap{}, %{coins: ["BTC", "ETH"]})
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(perps \\ %__MODULE__{}, attrs) do
    perps
    |> cast(attrs, [:coins])
    |> validate_required([:coins])
    |> validate_coins()
  end

  defp validate_coins(changeset) do
    validate_change(changeset, :coins, fn :coins, coins ->
      if Enum.all?(coins, &is_binary/1) do
        []
      else
        [coins: "all values must be strings"]
      end
    end)
  end

  # ===================== Helpers =====================

  @doc """
  Check if a specific coin is at its open interest cap.

  ## Parameters
    - `perps`: The perps at cap struct
    - `coin`: Coin symbol to check

  ## Returns
    - `boolean()`

  ## Example
      iex> at_cap?(%PerpsAtOpenInterestCap{coins: ["BTC", "ETH"]}, "BTC")
      true
  """
  @spec at_cap?(t(), String.t()) :: boolean()
  def at_cap?(%__MODULE__{coins: coins}, coin) when is_binary(coin) do
    coin in coins
  end

  @doc """
  Get the count of perps at their open interest cap.

  ## Parameters
    - `perps`: The perps at cap struct

  ## Returns
    - `non_neg_integer()`
  """
  @spec count(t()) :: non_neg_integer()
  def count(%__MODULE__{coins: coins}) do
    length(coins)
  end
end
