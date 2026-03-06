defmodule Hyperliquid.Api.Info.UserFunding do
  @moduledoc """
  User's funding payment history.

  Returns funding payments received or paid by a user for perpetual positions.

  See: https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint/perpetuals#retrieve-a-users-funding-history-or-non-funding-ledger-updates

  ## Usage

      {:ok, funding} = UserFunding.request("0x...", 1700000000000)
      {:ok, funding} = UserFunding.request("0x...", 1700000000000, endTime: 1700100000000)
  """

  use Hyperliquid.Api.Endpoint,
    type: :info,
    request_type: "userFunding",
    params: [:user, :startTime],
    optional_params: [:endTime],
    rate_limit_cost: 20,
    doc: "Retrieve a user's funding payment history",
    returns: "List of funding payment records"

  @type t :: %__MODULE__{
          payments: [Payment.t()]
        }

  @primary_key false
  embedded_schema do
    embeds_many :payments, Payment, primary_key: false do
      @moduledoc "Individual funding payment record."

      field(:time, :integer)
      field(:coin, :string)
      field(:usdc, :string)
      field(:szi, :string)
      field(:funding_rate, :string)
      field(:nSamples, :integer)
    end
  end

  # ===================== Preprocessing =====================

  @doc false
  def preprocess(data) when is_list(data), do: %{payments: data}
  def preprocess(data), do: data

  # ===================== Changesets =====================

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(funding \\ %__MODULE__{}, attrs) do
    funding
    |> cast(attrs, [])
    |> cast_embed(:payments, with: &payment_changeset/2)
  end

  defp payment_changeset(payment, attrs) do
    payment
    |> cast(attrs, [:time, :coin, :usdc, :szi, :funding_rate, :nSamples])
    |> validate_required([:time])
  end

  # ===================== Helpers =====================

  @doc """
  Get funding payments for a specific coin.
  """
  @spec by_coin(t(), String.t()) :: [map()]
  def by_coin(%__MODULE__{payments: payments}, coin) when is_binary(coin) do
    Enum.filter(payments, &(&1.coin == coin))
  end

  @doc """
  Get total funding amount in USDC.
  """
  @spec total_funding(t()) :: {:ok, float()} | {:error, :parse_error}
  def total_funding(%__MODULE__{payments: payments}) do
    total = payments |> Enum.map(&parse_float(&1.usdc)) |> Enum.sum()
    {:ok, total}
  end

  defp parse_float(str) do
    case Float.parse(str) do
      {f, _} -> f
      :error -> 0.0
    end
  end
end
