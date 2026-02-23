defmodule Hyperliquid.Api.Exchange.KeyUtils do
  @moduledoc """
  Shared utilities for resolving private keys and validating addresses in exchange modules.

  ## Private Key Resolution

  All exchange modules accept an optional `:private_key` in their opts keyword list.
  When not provided, the key is resolved from `Hyperliquid.Config.secret()`.
  If neither is available, a clear error is raised.

  ## Address Validation (Sensitive Actions)

  Transfer and withdrawal actions (UsdSend, Withdraw3, SpotSend, SendAsset,
  ApproveAgent, ApproveBuilderFee) accept an optional `:expected_address` in opts.
  When provided, `Signer.derive_address/1` is used to verify the private key
  matches the expected address, preventing accidental use of an agent sub-key
  for actions that require the real private key.

  ## Breaking Change (v0.2.0)

  `private_key` was previously the first positional argument in all exchange module
  functions. It is now an option in the opts keyword list (`:private_key`).
  """

  alias Hyperliquid.{Config, Signer}

  @doc """
  Resolves the private key from opts or application config.

  ## Options
    - `:private_key` - Explicit private key (hex string). Falls back to `Config.secret()`.

  Raises `ArgumentError` if no key is available.
  """
  @spec resolve_private_key!(keyword()) :: String.t()
  def resolve_private_key!(opts) do
    case Keyword.get(opts, :private_key) || Config.secret() do
      nil ->
        raise ArgumentError,
              "No private key provided and none configured. Pass :private_key option or set it in config."

      key ->
        key
    end
  end

  @doc """
  Validates that the private key derives to the expected address.

  Only performs validation when `:expected_address` is present in opts.
  Raises `ArgumentError` on mismatch.

  ## Options
    - `:expected_address` - Expected checksummed Ethereum address (0x-prefixed)
  """
  @spec validate_expected_address!(String.t(), keyword()) :: :ok
  def validate_expected_address!(private_key, opts) do
    case Keyword.get(opts, :expected_address) do
      nil ->
        :ok

      expected_address ->
        derived = Signer.derive_address(private_key)

        if String.downcase(derived) != String.downcase(expected_address) do
          raise ArgumentError,
                "Private key does not match expected address #{expected_address}. " <>
                  "Transfer/withdrawal actions require the real private key, not an agent key."
        end

        :ok
    end
  end

  @doc """
  Resolves private key and validates expected address for sensitive actions.

  Combines `resolve_private_key!/1` and `validate_expected_address!/2`.
  Use this for transfer/withdrawal modules (UsdSend, Withdraw3, SpotSend,
  SendAsset, ApproveAgent, ApproveBuilderFee).
  """
  @spec resolve_and_validate!(keyword()) :: String.t()
  def resolve_and_validate!(opts) do
    private_key = resolve_private_key!(opts)
    validate_expected_address!(private_key, opts)
    private_key
  end

  @doc """
  Signs EIP-712 typed data and returns the signature components.

  Wraps `Signer.sign_typed_data/5` with proper error handling,
  matching the pattern used by L1 action modules.

  ## Returns
    - `{:ok, %{r: r, s: s, v: v}}` on success
    - `{:error, {:signing_error, term()}}` on failure
  """
  @spec sign_typed_data(String.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, {:signing_error, term()}}
  def sign_typed_data(private_key, domain_json, types_json, message_json, primary_type) do
    case Signer.sign_typed_data(private_key, domain_json, types_json, message_json, primary_type) do
      %{"r" => r, "s" => s, "v" => v} -> {:ok, %{r: r, s: s, v: v}}
      error -> {:error, {:signing_error, error}}
    end
  end
end
