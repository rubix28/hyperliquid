# Changelog

## 0.2.3

- Added `Hyperliquid.Node` module for interacting with local Hyperliquid node endpoints
- 42 generated convenience functions for verified local info server endpoints with struct parsing
- Added 7 new endpoints: `allPerpMetas`, `allBorrowLendReserveStates`, `spotPairDeployAuctionStatus`, `subAccounts2`, `userDexAbstraction`, `alignedQuoteTokenInfo`, `perpDexLimits`
- Added 6 more node-verified info endpoints: `perpCategories`, `userAbstraction`, `approvedBuilders`, `borrowLendUserState`, `borrowLendReserveState`, `perpAnnotation`
- Optional `dex:` keyword arg support on `meta`, `clearinghouseState`, `openOrders`, `frontendOpenOrders`, `perpsAtOpenInterestCap`
- Refactored `@supported_endpoints` to 5-tuple format `{name, type, mod, required, optional}` for clean optional param generation
- Fixed `marginTable` to accept required `id` parameter
- Added generic single-param macro case for non-user params (`id`, `token`, `dex`)
- Documented full list of supported and unsupported local node endpoints
- Added new exchange endpoints: `BorrowLend`, `PerpDeploy`, `SpotDeploy`, `SpotUser`, `UserDexAbstraction`, `UserPortfolioMargin`
- Added new info endpoint: `UserBorrowLendInterest`
- Added new WebSocket subscriptions: `AllDexsAssetCtxs`, `AllDexsClearinghouseState`
- Generic `info_request/2` fallback for undocumented or future node endpoints
- File snapshot helpers (`file_snapshot/3`, `referrer_states_snapshot/2`, `l4_snapshots/2`)
- EVM RPC helpers via `:node` named RPC (`rpc_call/2`, `rpc_call!/2`)
- Added `node_info_request/2` to `Hyperliquid.Transport.Http`
- Independent `enable_node_info` and `enable_node_rpc` config flags
- Added `node_url/0`, `node_rpc_enabled?/0`, `node_info_enabled?/0` to `Hyperliquid.Config`

## 0.2.0

- Complete DSL migration: all endpoints defined via declarative macros (`use Endpoint`, `use SubscriptionEndpoint`)
- 62 Info endpoints, 38 Exchange endpoints, 26 WebSocket subscription channels
- Added Explorer API modules (`BlockDetails`, `TxDetails`, `UserDetails`) and Stats modules
- Added `Hyperliquid.Telemetry` with events for API, WebSocket, cache, RPC, and storage
- Added `:telemetry` instrumentation to WebSocket connection/manager, cache init, RPC transport, and storage writer
- Added `Hyperliquid.Transport.Rpc` for JSON-RPC calls to the Hyperliquid EVM
- Ecto schema validation and optional Postgres persistence for subscription data
- Private key is now optional with config fallback and address validation
- Fixed EIP-712 domain name and chainId for all exchange modules
- Normalized market order prices to tick size in asset-based builder

## 0.1.6

- Updated l2Book post req to include sigFig and mantissa values

## 0.1.5

- Added new userFillsByTime endpoint to info context

## 0.1.4

- Added nSigFigs and mantissa optional params to l2Book subscription, add streamer pid to msg

## 0.1.3

- Added functions to cache for easier access and allow intellisense to help you see what's available
