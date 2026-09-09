# Uniswap V4 Developer Feedback

## Hook: Oscillon — Oracle-Aware LP Protection

### What we built

A Uniswap V4 `beforeSwap` hook that reads a primary price oracle (Chainlink where a native feed exists, RedStone's Chainlink-compatible feeds where it doesn't) before every swap, falls back to the pool's own 30-minute TWAP when the primary source is stale or disagrees with it by more than a threshold, computes deviation from the $1 peg, and charges drain-direction swaps (selling the below-peg token) proportionally to that deviation.

### What worked well

- Hook permissions system (`Hooks.Permissions`) is clean and explicit — easy to reason about exactly which callbacks are active and why
- `beforeSwap` fee override via `LPFeeLibrary.OVERRIDE_FEE_FLAG` works exactly as documented
- `PoolManager.initialize` with a custom `sqrtPriceX96` worked cleanly once we accounted for the fact that v4 prices in raw token-unit ratios, not dollar-normalized amounts — worth calling out since it's an easy, non-obvious trap for any pool pairing tokens with different decimals (we hit it directly: a naive 1:1 initial price is silently wrong by 10^12 for an 18-vs-6-decimal pair)

### Pain points

- No standard interface for hooks to expose derived state to external callers — we designed our own `getPoolState()` view function from scratch, with no SDK convention to follow or compare against
- Testing hook interactions with `PoolManager` requires significant boilerplate: the `@uniswap/v4-core` and `v4-core-test` utility import paths remap to physically different files, so identical types (`PoolId`, `PoolKey`) get treated as incompatible by the compiler across that boundary — we had to fall back to low-level `staticcall`/`call` in several test files just to invoke our own hook's external functions
- Nothing in v4 itself addresses oracle integration (staleness, cross-source disagreement, decimals-aware pricing) — reasonably, since that's application-specific — but it means every price-aware hook is solving the same staleness/fallback/decimals problems from scratch with no shared reference pattern

### Suggested improvements

- A standard (optional) interface convention for hooks to expose current state/regime to indexers and frontends — even just a naming convention would help, since every hook currently invents its own shape from zero
- Hook-testing utilities in the SDK that bridge the `v4-core` / `v4-core-test` type-remapping gap, so tests don't need low-level calls just to invoke a hook's own functions
- Reference examples (not built-in helpers — oracle logic is inherently app-specific) for common oracle-integration patterns: staleness handling, TWAP fallback, and decimals-aware pricing for non-uniform-decimal pairs, since these recur for any price-aware hook, not just stable/stable ones

### Deployed contracts

- OscillonHook: `0xF7ebe984E379a07cbD6465d277525D7B6D0290c0`
- Network: Ethereum Sepolia
- Pools: USDe/USDC, USDe/USDT, USDC/USDT
