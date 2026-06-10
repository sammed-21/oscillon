# OscillonHook

Inventory-risk protection hook for Uniswap v4 stable pools.

/\*

- ╔══════════════════════════════════════════════════════════════════╗
- ║ OscillonHook.sol v2.0 — Multi-Pool ║
- ║ ║
- ║ ARCHITECTURE CHANGE vs v1.x: ║
- ║ v1: immutable ORACLE0/ORACLE1/STABLE0/STABLE1 ║
- ║ → hardcoded to ONE pool forever at deploy ║
- ║ ║
- ║ v2: mapping(PoolId => PoolConfig) ║
- ║ → owner calls registerPool() for each stable pair ║
- ║ → supports USDC/USDT, USDC/DAI, USDT/DAI, ║
- ║ USDC/crvUSD, any stable pair with Chainlink feeds ║
- ║ ║
- ║ FREEZE REMOVED: ║
- ║ v1: severe depeg → revert PoolFrozen() → pool bricked ║
- ║ v2: severe depeg → fee capped at MAX_FEE_PIPS (50 bps) ║
- ║ swaps still flow, LPs still protected, nothing breaks ║
- ║ ║
- ║ Supported pools (register after deploy): ║
- ║ • USDC / USDT ║
- ║ • USDC / DAI ║
- ║ • USDT / DAI ║
- ║ • USDC / crvUSD ║
- ║ • any stable pair with a Chainlink USD feed ║
- ╚══════════════════════════════════════════════════════════════════╝
  \*/

## Overview

`OscillonHook` is a `beforeSwap` hook that protects LP inventory during stablecoin depeg events.
It monitors token-specific oracle prices, computes off-peg severity, and applies defensive fee/circuit-breaker policy.

Designed for stable/stable pools such as USDC/USDT and USDC/DAI.

## What It Does

Implementation: `src/OscillonHook.sol`

1. Validates pool is composed of configured stables (`STABLE0`, `STABLE1`).
2. Reads the oracle for the input stable token.
3. Computes absolute depeg in basis points from $1.
4. Applies dynamic fee policy with deep-depeg protections.
5. Emits `DepegDetected(depegBps, fee, swapSize)`.

## Policy

Constants:

- `SMALL_DEPEG_BPS = 7`
- `DRAIN_DEPEG_BPS = 20`
- `FREEZE_DEPEG_BPS = 60`
- `RESTORE_WINDOW = 1 hours`

Fee tiers (LP fee override pips):

- Base: `100` (~1 bps)
- Small depeg: `800` (~8 bps)
- Drain tier: `2800` (~28 bps)
- Restore tier: `30` (~0.3 bps)

Notes:

- Severe depeg (`>= FREEZE_DEPEG_BPS`) freezes the path with `PoolFrozen()`.
- Deep-depeg swap-size cap now applies to both exact-in and exact-out requests.
- `RESTORE_FEE_PIPS` is intentionally lower than base to incentivize post-stress rebalancing flow.

## Security

- Hook entrypoints are restricted by `onlyPoolManager` (via `BaseHook`).
- Direct non-manager calls revert.
- Oracle sanity checks include:
  - positive price
  - not future timestamp
  - fresh data within 1 hour

Liquidity operations remain available:

- `beforeAddLiquidity = false`
- `beforeRemoveLiquidity = false`
- `afterAddLiquidity = false`
- `afterRemoveLiquidity = false`

## Testing

Tests: `test/OscillonHook.t.sol`

- `test_beforeSwap_AppliesPolicyLadder_WhenUSDTDepegs()`
- `test_beforeSwap_AppliesPolicyLadder_WhenUSDCDepegs()`
- `test_beforeSwap_Reverts_WhenCallerIsNotPoolManager()`
- `test_beforeSwap_Reverts_WhenInputStableIsAbovePegByFreezeThreshold()`
- `test_beforeSwap_Reverts_WhenExactOutputExceedsDeepDepegCap()`

Run:

```bash
forge test -vvv
```

## Deployment Script

A CREATE2 + HookMiner deployment script is included:

- `script/DeployOscillonHook.s.sol`

Required env vars:

- `POOL_MANAGER`
- `ORACLE0`
- `STABLE0`
- `STABLE0_DECIMALS`
- `ORACLE1`
- `STABLE1`
- `STABLE1_DECIMALS`

Example:

```bash
forge script script/DeployOscillonHook.s.sol:DeployOscillonHookScript --broadcast --rpc-url <RPC_URL>
```

## Build Commands

```bash
forge build
forge test
forge fmt
forge snapshot
```

## Known Limitations (Pre-Audit)

**Surplus accounting (indicative only)**

`surplusAccrued` and `protocolAccrued` track theoretical LP surplus from dynamic fees but are not connected to actual v4 fee settlement. These values are meaningful as indicators of mechanism activity but `collectProtocolFees` is not safe for production use without implementing proper fee skimming via `donate()` or `afterSwapReturnDelta`. This is a known P0 for mainnet — deferred for POC submission.

**Rounding direction**

Fee surplus math uses `mulDivDown` throughout. This is conservative (slightly under-charges). A production deployment would implement `mulDivUp` on surplus accrual per the rounding policy documented in the audit report.

**K parameter liquidity threshold**

`THIN_POOL_LIQUIDITY` comparison uses incorrect units (USDC atoms vs AMM liquidity units). Fixed by using `K_STANDARD=45` universally in this version.

## MVP Limitations

- Static thresholds and fee tiers (not governance-tunable yet)
- Single oracle feed per token (no fallback aggregation)
- Economic parameter calibration should be validated with deeper simulation
