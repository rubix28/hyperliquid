defmodule Hyperliquid.Api.Exchange.Modify do
  @moduledoc """
  Modify a single existing order on Hyperliquid.

  For modifying multiple orders in a batch, use `Hyperliquid.Api.Exchange.BatchModify`.

  See: https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/exchange-endpoint#modify-an-order
  """

  require Logger

  alias Hyperliquid.Config
  alias Hyperliquid.Api.Exchange.Order

  # ===================== Types =====================

  @type modify_opts :: [
          vault_address: String.t()
        ]

  @type modify_response :: %{
          status: String.t(),
          response: map()
        }

  # ===================== Request Functions =====================

  @doc """
  Modify a single order.

  ## Parameters
    - `oid`: Order ID to modify (integer or hex string for Client Order ID)
    - `order`: New order parameters (built with `Order.limit_order/4` or `Order.trigger_order/5`)
    - `opts`: Optional parameters

  ## Options
    - `:private_key` - Private key for signing (falls back to config)
    - `:vault_address` - Modify on behalf of a vault

  ## Returns
    - `{:ok, response}` - Modify result
    - `{:error, term()}` - Error details

  ## Examples

      # Modify order with new price
      alias Hyperliquid.Api.Exchange.{Modify, Order}

      new_order = Order.limit_order("BTC", true, "51000.0", "0.1")
      {:ok, result} = Modify.modify(12345, new_order)

  ## Breaking Change (v0.2.0)
  `private_key` was previously the first positional argument. It is now
  an option in the opts keyword list (`:private_key`).
  """
  @spec modify(non_neg_integer() | String.t(), Order.order(), modify_opts()) ::
          {:ok, modify_response()} | {:error, term()}
  def modify(oid, order, opts \\ []) do
    # Note: The API doesn't have a separate "modify" action type.
    # Instead, we use "batchModify" with a single modification.
    # This is the supported way to modify a single order.
    alias Hyperliquid.Api.Exchange.BatchModify

    debug("modify called (delegating to batchModify)", %{
      oid: oid,
      vault_address: Keyword.get(opts, :vault_address)
    })

    BatchModify.modify_batch([%{oid: oid, order: order}], opts)
  end

  # ===================== Helper Functions =====================

  defp debug(message, data) do
    if Config.debug?() do
      Logger.debug("[Modify] #{message}", data: data)
    end

    :ok
  end
end
