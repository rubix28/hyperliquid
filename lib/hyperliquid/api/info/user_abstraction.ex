defmodule Hyperliquid.Api.Info.UserAbstraction do
  @moduledoc """
  User's account abstraction mode.

  Returns the account abstraction configuration: unified account, portfolio margin, or disabled.

  See: https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint

  ## Usage

      {:ok, abstraction} = UserAbstraction.request("0x...")
  """

  use Hyperliquid.Api.Endpoint,
    type: :info,
    request_type: "userAbstraction",
    params: [:user],
    rate_limit_cost: 1,
    doc: "Retrieve user's account abstraction mode",
    returns: "Account abstraction mode (disabled, unifiedAccount, or portfolioMargin)"

  @type t :: %__MODULE__{
          mode: String.t() | nil
        }

  @primary_key false
  embedded_schema do
    field(:mode, :string)
  end

  # ===================== Preprocessing =====================

  @doc false
  def preprocess(data) when is_binary(data), do: %{mode: data}
  def preprocess(nil), do: %{mode: nil}
  def preprocess(data) when is_map(data), do: data

  # ===================== Changesets =====================

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(abstraction \\ %__MODULE__{}, attrs) do
    abstraction
    |> cast(attrs, [:mode])
  end

  # ===================== Helpers =====================

  @doc """
  Check if unified account mode is enabled.
  """
  @spec unified_account?(t()) :: boolean()
  def unified_account?(%__MODULE__{mode: mode}), do: mode == "unifiedAccount"

  @doc """
  Check if portfolio margin mode is enabled.
  """
  @spec portfolio_margin?(t()) :: boolean()
  def portfolio_margin?(%__MODULE__{mode: mode}), do: mode == "portfolioMargin"

  @doc """
  Check if abstraction is disabled.
  """
  @spec disabled?(t()) :: boolean()
  def disabled?(%__MODULE__{mode: mode}), do: mode == "disabled" or is_nil(mode)
end
