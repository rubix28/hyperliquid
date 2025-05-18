defmodule Hyperliquid.Api.Evm do
  use Hyperliquid.Api, context: "evm"

  def block_number do
    post(%{
      jsonrpc: "2.0",
      method: "eth_blockNumber",
      params: [],
      id: 1
    })
  end

  def chain_id() do
    post(%{
      jsonrpc: "2.0",
      method: "eth_chainId",
      params: [],
      id: 1
    })
  end
end
