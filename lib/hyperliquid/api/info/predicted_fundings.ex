defmodule Hyperliquid.Api.Info.PredictedFundings do
  @moduledoc """
  Predicted funding rates for perpetuals.

  Returns funding rate predictions across different venues for each coin.
  The response is a nested array structure: [coin, [[venue, {fundingRate, nextFundingTime}]]]

  See: https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint/perpetuals
  """

  use Hyperliquid.Api.Endpoint,
    type: :info,
    request_type: "predictedFundings",
    params: [],
    rate_limit_cost: 2,
    doc: "Retrieve predicted funding rates for perpetuals",
    returns: "Funding rate predictions across different venues"

  @type t :: %__MODULE__{
          predictions: [CoinPrediction.t()]
        }

  @primary_key false
  embedded_schema do
    embeds_many :predictions, CoinPrediction, primary_key: false do
      @moduledoc "Funding predictions for a specific coin."

      field(:coin, :string)

      embeds_many :venues, VenuePrediction, primary_key: false do
        @moduledoc "Funding prediction for a specific venue."

        field(:venue, :string)
        field(:funding_rate, :string)
        field(:next_funding_time, :integer)
      end
    end
  end

  # ===================== Preprocessing =====================

  @doc false
  def preprocess(data) when is_list(data) do
    %{predictions: data}
  end

  def preprocess(data), do: data

  # ===================== Changesets =====================

  @doc """
  Creates a changeset for predicted fundings data.

  ## Parameters
    - `predictions`: The predictions struct
    - `attrs`: Nested array from API response

  ## Returns
    - `Ecto.Changeset.t()`
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(predictions \\ %__MODULE__{}, attrs)

  def changeset(predictions, %{predictions: attrs}) when is_list(attrs) do
    parsed_predictions = Enum.map(attrs, &parse_coin_prediction/1)

    predictions
    |> cast(%{}, [])
    |> put_embed(:predictions, parsed_predictions)
  end

  def changeset(predictions, attrs) do
    predictions
    |> cast(attrs, [])
    |> put_embed(:predictions, [])
  end

  defp parse_coin_prediction([coin, venues]) when is_binary(coin) and is_list(venues) do
    %__MODULE__.CoinPrediction{
      coin: coin,
      venues: Enum.map(venues, &parse_venue_prediction/1)
    }
  end

  defp parse_coin_prediction(_), do: %__MODULE__.CoinPrediction{coin: "", venues: []}

  defp parse_venue_prediction([venue, %{"fundingRate" => rate, "nextFundingTime" => time}]) do
    %__MODULE__.CoinPrediction.VenuePrediction{
      venue: venue,
      funding_rate: rate,
      next_funding_time: time
    }
  end

  defp parse_venue_prediction([venue, %{funding_rate: rate, next_funding_time: time}]) do
    %__MODULE__.CoinPrediction.VenuePrediction{
      venue: venue,
      funding_rate: rate,
      next_funding_time: time
    }
  end

  defp parse_venue_prediction(_) do
    %__MODULE__.CoinPrediction.VenuePrediction{
      venue: "",
      funding_rate: "0",
      next_funding_time: 0
    }
  end

  # ===================== Helpers =====================

  @doc """
  Get funding predictions for a specific coin.

  ## Parameters
    - `predicted_fundings`: The predicted fundings struct
    - `coin`: Coin symbol

  ## Returns
    - `{:ok, [VenuePrediction.t()]}` if found
    - `{:error, :not_found}` if not found
  """
  @spec get_coin(t(), String.t()) :: {:ok, [map()]} | {:error, :not_found}
  def get_coin(%__MODULE__{predictions: predictions}, coin) when is_binary(coin) do
    case Enum.find(predictions, &(&1.coin == coin)) do
      nil -> {:error, :not_found}
      %{venues: venues} -> {:ok, venues}
    end
  end

  @doc """
  Get all coins with predictions.

  ## Parameters
    - `predicted_fundings`: The predicted fundings struct

  ## Returns
    - List of coin symbols
  """
  @spec coins(t()) :: [String.t()]
  def coins(%__MODULE__{predictions: predictions}) do
    Enum.map(predictions, & &1.coin)
  end

  @doc """
  Get the funding rate for a specific coin and venue.

  ## Parameters
    - `predicted_fundings`: The predicted fundings struct
    - `coin`: Coin symbol
    - `venue`: Venue name

  ## Returns
    - `{:ok, String.t()}` if found
    - `{:error, :not_found}` if not found
  """
  @spec get_rate(t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def get_rate(%__MODULE__{} = pf, coin, venue) do
    with {:ok, venues} <- get_coin(pf, coin),
         %{funding_rate: rate} <- Enum.find(venues, &(&1.venue == venue)) do
      {:ok, rate}
    else
      _ -> {:error, :not_found}
    end
  end
end
