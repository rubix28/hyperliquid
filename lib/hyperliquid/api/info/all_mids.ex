defmodule Hyperliquid.Api.Info.AllMids do
  @moduledoc """
  Mapping of coin symbols to mid prices.

  This endpoint returns a dynamic map where keys are coin symbols (e.g., "BTC", "ETH")
  and values are mid prices as strings.

  See: https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint#retrieve-mids-for-all-coins

  ## Usage

      {:ok, all_mids} = AllMids.request()
      {:ok, price} = AllMids.get_mid(all_mids, "BTC")
      # => {:ok, "43250.5"}

      # Or with bang variant
      all_mids = AllMids.request!()
  """

  use Hyperliquid.Api.Endpoint,
    type: :info,
    request_type: "allMids",
    optional_params: [:dex],
    rate_limit_cost: 2,
    raw_response: true,
    doc: "Retrieve mid prices for all actively traded coins",
    returns: "Map of coin symbols to mid prices as strings"

  # Function heads with defaults + convenience overloads (grouped by function name)
  def request(opts \\ [])
  def request(dex) when is_binary(dex), do: request(dex: dex)

  def request!(opts \\ [])
  def request!(dex) when is_binary(dex), do: request!(dex: dex)

  @type t :: %__MODULE__{
          mids: %{String.t() => String.t()},
          dex: String.t() | nil
        }

  @primary_key false
  embedded_schema do
    # Map of coin symbols to mid prices
    # Example: %{"BTC" => "43250.5", "ETH" => "2280.75"}
    field(:mids, :map)
    # DEX name (nil for main dex)
    field(:dex, :string)
  end

  # ===================== Changeset =====================

  @doc """
  Creates a changeset for all mids data.

  ## Parameters
    - `all_mids`: The all mids struct
    - `attrs`: Map of coin symbols to mid prices
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(all_mids \\ %__MODULE__{}, attrs) when is_map(attrs) do
    # For allMids, the attrs themselves are the mids map (unless it has a "mids" key)
    normalized =
      if Map.has_key?(attrs, "mids") or Map.has_key?(attrs, :mids) do
        attrs
      else
        %{mids: attrs}
      end

    all_mids
    |> cast(normalized, [:mids, :dex])
    |> validate_required([:mids])
    |> validate_mids()
  end

  defp validate_mids(changeset) do
    validate_change(changeset, :mids, fn :mids, mids ->
      case validate_mids_map(mids) do
        :ok -> []
        {:error, reason} -> [mids: reason]
      end
    end)
  end

  defp validate_mids_map(mids) when is_map(mids) do
    invalid_entries =
      Enum.filter(mids, fn
        {key, value} when is_binary(key) and is_binary(value) -> false
        _ -> true
      end)

    case invalid_entries do
      [] -> :ok
      _ -> {:error, "all keys and values must be strings"}
    end
  end

  defp validate_mids_map(_), do: {:error, "must be a map"}

  # ===================== Helpers =====================

  @doc """
  Get the mid price for a specific coin.

  ## Example

      iex> get_mid(%AllMids{mids: %{"BTC" => "43250.5"}}, "BTC")
      {:ok, "43250.5"}

      iex> get_mid(%AllMids{mids: %{"BTC" => "43250.5"}}, "DOGE")
      {:error, :not_found}
  """
  @spec get_mid(t(), String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def get_mid(%__MODULE__{mids: mids}, coin) when is_binary(coin) do
    case Map.fetch(mids, coin) do
      {:ok, price} -> {:ok, price}
      :error -> {:error, :not_found}
    end
  end

  @doc """
  Get all coin symbols.

  ## Example

      iex> get_coins(%AllMids{mids: %{"BTC" => "43250.5", "ETH" => "2280.75"}})
      ["BTC", "ETH"]
  """
  @spec get_coins(t()) :: [String.t()]
  def get_coins(%__MODULE__{mids: mids}) do
    Map.keys(mids)
  end

  @doc """
  Convert the mids map to a list of {coin, price} tuples.

  ## Example

      iex> to_list(%AllMids{mids: %{"BTC" => "43250.5", "ETH" => "2280.75"}})
      [{"BTC", "43250.5"}, {"ETH", "2280.75"}]
  """
  @spec to_list(t()) :: [{String.t(), String.t()}]
  def to_list(%__MODULE__{mids: mids}) do
    Map.to_list(mids)
  end
end
