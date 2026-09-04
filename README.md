# Oscillon Hook

**Inventory-risk protection for Uniswap v4 stable pools.**

Oscillon is a dynamic-fee hook that monitors oracle prices on the token being sold, detects depeg conditions, and applies a **base fee plus depeg surcharge** so liquidity providers are compensated when traders drain below-peg stablecoins.

Designed for stable/stable pools such as USDC/USDT, USDe/USDC, and USDe/USDT.

---

## Why Oscillon Exists

Static swap fees (e.g. 3 bps flat) do not scale with depeg risk. When a stablecoin trades below $1, arbitrageurs can extract value from the pool while LPs absorb impaired inventory. Oscillon raises fees on **drain swaps** (selling the below-peg asset) while keeping normal swaps competitive at peg.

---

## How It Works

```
Swap (user sells tokenIn)
        │
        ▼
┌───────────────────────────────────────┐
│  OscillonHook.beforeSwap              │
│  1. Identify input token (token0/1)   │
│  2. Read Chainlink/RedStone + TWAP    │
│  3. Compute depegBps + isDrain        │
│  4. Select fee = base + surcharge     │
│  5. Enforce swap-size cap (>=15 bps)  │
│  6. Emit DepegDetected                │
└───────────────────────────────────────┘
        │
        ▼
   Uniswap v4 applies override fee
```

| Component | Role |
|-----------|------|
| `ChainlinkOracleAdapter` | Primary USD price per token — works with any `AggregatorV3Interface`-shaped feed (Chainlink or RedStone's Chainlink-compatible feeds; no separate RedStone adapter needed) |
| `OscillonTwapOracle` | 30-minute pool TWAP fallback, decimals-aware |
| `OscillonPriceEngine` | Blends sources; disagreement guard at 20 bps |
| `OscillonFeePolicy` | Hybrid piecewise + quadratic surcharge curve |
| `OscillonHook` | Orchestrates policy and returns dynamic fee |
| `PythAdapter` | Skeleton only — implements `IOscillonOracle` for a Pyth pull-based feed, **not wired into any deployed pool** (see [Known Limitations](#known-limitations)) |

**Drain swap** = user sells the token that is below $1 (`pegBelow = true`).
**Restore swap** = user sells the above-peg token → base fee only.

---

## Fee Model

Oscillon uses **base fee + depeg surcharge** (not a replacement curve):

```
total fee = BASE_FEE (3 bps) + depeg surcharge (hybrid curve)
```

| Scenario | Fee (approx.) |
|----------|----------------|
| At peg, any direction | **3 bps** base |
| 6 bps drain (sell below-peg token) | **4 bps** (3 + 1) |
| 20 bps drain | **9 bps** (3 + 6) |
| Restore direction (sell above-peg) | **3 bps** base |
| Max cap | **50 bps** |

Constants (`OscillonConstants.sol`):

- `BASE_FEE_PIPS = 300` (3 bps)
- `SMALL_DEPEG_BPS = 3` — dynamic fee curve starts here
- `MAX_FEE_PIPS = 5000` (50 bps)
- `MAX_ORACLE_AGE = 1 hour` (aligned with intraday depeg / fee-curve horizon; Chainlink-tuned — RedStone adapters override this per-deployment, see [Oracle Providers](#oracle-providers))
- `ORACLE_DISAGREE_BPS = 20` — cross-source (primary vs TWAP) blend threshold
- `CAP_DEPEG_BPS = 15` — swap-size cap only activates at/above this depeg; below it, drain swaps are fully priced via the surcharge with no size limit, so routine volume isn't blocked
- `MAX_DEPEG_SWAP_FACTOR = 500_000` — absolute per-token cap ceiling (paired with a 0.5%-of-liquidity cap, whichever binds)

On each swap the hook emits:

```solidity
event DepegDetected(
    PoolId indexed poolId,
    uint256 depegBps,
    uint24 feeApplied,
    uint256 swapSize,
    bool isDrain,
    bool usingFallback,
    bool twapWarmedUp,
    bool tokenInIsToken0
);
```

`twapWarmedUp` and `tokenInIsToken0` are reporting-only — neither changes `feeApplied`.

- `twapWarmedUp` is `false` whenever the TWAP price used in this swap is raw spot rather than a real windowed average — either the ring buffer hasn't spanned the full 30-minute `TWAP_WINDOW` yet, or (as of the current fix) it has fewer than 2 real observations, since a single synthetic seed observation extrapolated across elapsed time produces nonsense, not a real average. See [Known Limitations](#known-limitations) and `THREAT_MODEL.md` §1.2.
- `tokenInIsToken0` says which side `depegBps` refers to — needed for indexers/subgraphs to attribute a reading to a specific token without a separate join against the raw `PoolManager.Swap` event.

---

## Backtest Results

Historical simulations on USDC/USDT swap data compare Oscillon against a static 3 bps fee. Two periods are shown: a calm month (May 2026) and the USDC depeg crisis (March 2023).

### May 2026 — normal market conditions

~18,500 chronological swaps with low volatility. Oscillon keeps fees near the 3 bps base while static and dynamic models earn similar total income (~$65k). The benefit shows up in the **3–7 bps deviation** bucket, where static LP capture drops to ~85% and Oscillon stays near 100%.

![Backtest May 2026](assets/backtest-2026-05.png)

### March 2023 — USDC depeg crisis

#### Minute-by-minute fee response

Chainlink-matched replay from March 10–16, 2023. As USDC depegged to ~1,200 bps, Oscillon scaled fees from 3 bps to the 50 bps cap while static stayed flat.

![Depeg timeline March 2023](assets/depeg-timeline-2023-03.png)

*Top: oracle depeg magnitude. Middle: static 3 bps vs Oscillon hybrid. Bottom: remaining arb gap after fee (drain protection proxy).*

#### Full-period dashboard (~6,200 swaps)

Fee curves, LVR distribution, cumulative LP income, and LP capture % over the March 2023 stress window. Income spikes around swap 2,500–3,500 when the depeg hit. Oscillon hybrid ends ~2× static (~$450k vs ~$215k) and holds 25–50% LP capture in the 15–30+ bps ranges where static collapses below 10%.

![Backtest March 2023](assets/backtest-2023-03.png)

#### Model comparison (same period)

Side-by-side fee models including hybrid, piecewise, quadratic (K=45), and additive (base + drain tax). Additive and paper-minimum benchmarks show the upper bound on LP protection.

![Backtest results March 2023](assets/backtest-results.png)

> Backtests are illustrative simulations on historical data. On-chain behavior depends on oracle freshness, pool liquidity, and swap direction. See [Known Limitations](#known-limitations).

---

## Architecture

```
src/
├── OscillonHook.sol                    # beforeSwap fee override + pool registry
├── oracle/
│   ├── IOscillonOracle.sol             # common adapter interface (price sources)
│   ├── IChainlinkAggregator.sol        # minAnswer/maxAnswer + proxy-resolution interfaces
│   ├── IChainlinkSequencer.sol
│   ├── OscillonPriceEngine.sol         # primary-source + TWAP cascade, disagreement guard
│   └── adapters/
│       ├── ChainlinkOracleAdapter.sol  # wraps any AggregatorV3Interface feed
│       └── PythAdapter.sol             # skeleton only, not wired in — see below
├── libraries/
│   ├── OscillonFeePolicy.sol           # hybrid surcharge curve
│   ├── OscillonDepegMath.sol           # depeg bps + disagreement guard math
│   └── OscillonTwapOracle.sol          # in-pool TWAP ring buffer, decimals-aware
├── types/
│   └── OscillonTypes.sol
├── errors/
│   └── OscillonErrors.sol
└── constants/
    └── OscillonConstants.sol

script/
└── DeployOscillon.s.sol   # single-pool path (Anvil/Arbitrum) + multi-pool path (Sepolia)

test/
├── OscillonHook.t.sol           # depeg/fee, TWAP ring buffer, answer-bound, decimal-mismatch
├── OscillonFeePolicy.t.sol
├── ChainlinkOracleAdapter.t.sol # minAnswer/maxAnswer circuit breaker, isolated from the hook
└── OscillonInvariants.t.sol     # pure fuzz + stateful invariant campaign (see THREAT_MODEL.md §6)
```

**Multi-pool support:** owner calls `registerPool()` per stable pair with an approved oracle adapter for each token. No pool freeze — severe depeg caps fee at 50 bps; swaps continue.

---

## Oracle Providers

`ChainlinkOracleAdapter` only depends on the standard `AggregatorV3Interface` shape (`decimals()`, `latestRoundData()`) — it doesn't care what's behind that interface, so it works unmodified with any source that implements it, not just Chainlink itself. Currently deployed against two:

- **Chainlink** — used where a native feed exists (e.g. USDe/USD on Sepolia). `maxAge` defaults to `MAX_ORACLE_AGE` (1h), tuned to Chainlink's typical heartbeat.
- **RedStone (Classic/push feeds)** — used where no native Chainlink feed exists (e.g. USDC/USD and USDT/USD on Sepolia). RedStone's push-style feeds are deliberately ABI-identical to Chainlink's for exactly this drop-in compatibility. RedStone's heartbeat here is ~6h, not Chainlink's ~1h, so RedStone-backed adapters are constructed with a longer explicit `maxAge` override — reusing the Chainlink-tuned default would treat a perfectly on-schedule RedStone update as stale 5 of every 6 hours.

**Gap worth knowing:** the minAnswer/maxAnswer floor/ceiling circuit breaker (see [Security](#security)) only works when the underlying feed exposes those functions. RedStone's feeds don't — `_tryFetchBounds` gracefully degrades (`boundsKnown = false`, check skipped) rather than reverting, but it means that specific defense only protects Chainlink-sourced legs of a pool, not RedStone-sourced ones.

**Pyth:** `PythAdapter.sol` exists as a skeleton implementing `IOscillonOracle` against a locally-defined minimal `IPyth` interface (no external SDK dependency). It is **not approved or registered on any deployed pool** — Pyth's pull model (someone must push a fresh price via `updatePriceFeeds()` before each read, with no automatic keeper) is a real operational dependency this project hasn't taken on. Wiring it in for real is a config change (`approveAdapter` + `registerPool`/`updatePoolChainlinkOracle`), not a code change.

---

## Quick Start

### Build & test

```bash
forge build
forge test                                    # 32 tests, all suites
forge test --match-contract OscillonHookInvariants -vv   # slow stateful invariant campaign (~15 min)
```

### Deploy (Anvil local)

```bash
# Terminal 1
anvil --chain-id 31337

# Terminal 2
source .env   # PRIVATE_KEY must have 0x prefix
forge script script/DeployOscillon.s.sol:DeployOscillon \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast
```

Deployment addresses are written to `deployment.json` and `oscillon-ui/src/deployment.json`.

### Deploy (Arbitrum Sepolia / Arbitrum) — single pool

```bash
forge script script/DeployOscillon.s.sol:DeployOscillon \
  --rpc-url "$RPC_URL" \
  --broadcast
```

### Deploy (Ethereum Sepolia) — 3-pool multi-pool path

`chainId == 11155111` routes through a dedicated multi-pool deploy (`_deployMultiPoolSepolia`), separate from the single-pool path above, that mints 3 mock tokens (USDe 18dec, USDC 6dec, USDT 6dec) and registers **USDC/USDT, USDe/USDC, and USDe/USDT** against real, on-chain-verified feeds:

```bash
source .env
forge script script/DeployOscillon.s.sol:DeployOscillon \
  --rpc-url "$RPC_URL" \
  --broadcast \
  --verify \
  --etherscan-api-key "$ETHERSCAN_API_KEY"
```

Writes a flat record under the `"11155111"` key in `deployment.json` — token/adapter/feed addresses plus each pool's `currency0`/`currency1`/`poolId` (`usdcUsdt_*`, `usdeUsdc_*`, `usdeUsdt_*` prefixes). No verified real USDT/USD Chainlink feed exists on Sepolia (checked extensively) — USDC and USDT are priced via RedStone instead; only USDe uses a native Chainlink feed.

Pool initial price and liquidity are decimals-aware, not flat constants — see [Known Limitations](#known-limitations) for why that matters and what was fixed.

**Deploy key hygiene:** use a plain EOA reserved for CLI deploys only. A key that's also imported into a browser wallet (e.g. for testing the swap UI) can get silently upgraded to an EIP-7702 delegated smart account by the wallet app, which causes `forge script --broadcast` to intermittently fail with nonce/mempool errors that have nothing to do with the contracts. Keep deploy keys and interactive-testing keys separate.

---

## Frontend Integration

The UI should show **three linked values** per swap:

1. **Hook price** — effective USD price for the input token (primary oracle + TWAP logic)
2. **Depeg deviation** — bps from $1 for that token
3. **Total fee** — base (3 bps) + surcharge, from `DepegDetected` or swap simulation

Use `getDeployment(chainId)` (single-pool chains) or `getMultiPoolDeployment(chainId)` / `getSepoliaPools()` (Ethereum Sepolia) from `oscillon-ui/src/deployment.config.ts`.
Fee quotes must be **per swap direction** — use `depegBps0` / `depegBps1` from `getPoolState()` for the correct token. `getPoolState()` also returns `twapWarmedUp` (11th field) — surface it so a raw-spot-priced fallback reading isn't presented as a real windowed average.

---

## Security

- Hook callbacks restricted to `PoolManager` via `BaseHook`
- Oracle staleness: `block.timestamp > updatedAt + maxAge` → TWAP fallback (`maxAge` is per-adapter, see [Oracle Providers](#oracle-providers))
- **minAnswer/maxAnswer circuit breaker**: if a feed's underlying aggregator is clamped at its configured floor/ceiling (the LUNA/UST failure mode — an aggregator can keep reporting a saturated value instead of reverting), the adapter reverts rather than trusting it, routing through the same TWAP-fallback path staleness uses. Only works where the feed exposes `minAnswer()`/`maxAnswer()` — see the RedStone gap noted in [Oracle Providers](#oracle-providers)
- Oracle disagreement > 20 bps → conservative price (closer to $1)
- Exact-output swaps disabled when `depegBps >= 3`
- Swap-size cap (`min(MAX_DEPEG_SWAP_FACTOR, 0.5% of pool liquidity)`) only activates at `depegBps >= CAP_DEPEG_BPS (15)` — mild deviations are priced via the surcharge, not size-limited, so routine volume isn't throttled by a control meant for severe events
- Rolling drain multiplier increases fee under sustained drain pressure

Liquidity add/remove is unrestricted (no hook on LP operations).

See `THREAT_MODEL.md` for the full adversary model, sourced defense parameters, and explicit scope boundaries.

---

## Known Limitations

**Surplus accounting (indicative only)**
`surplusAccrued` and `protocolAccrued` track theoretical surplus from dynamic fees but are not connected to actual v4 fee settlement. `collectProtocolFees` requires proper fee skimming via `donate()` or `afterSwapReturnDelta` for production.

**Oracle latency**
TWAP window is 30 minutes. During fast depegs, TWAP can lag spot. Primary-source freshness uses a `maxAge` tuned per provider (1h Chainlink, 7h RedStone on the current Sepolia deployment) before falling back to TWAP.

**Decimals-mismatched pools need decimals-aware pricing and seeding — now fixed, but was not always true.** v4 prices in raw smallest-unit ratios, not dollar-normalized amounts. For a pool pairing tokens with different decimals (e.g. USDe 18 vs USDC 6), a naive `SQRT_PRICE_1_1` init or flat `liquidityDelta` constant is wrong by orders of magnitude (10^12 in this case) — this was found and fixed across three related spots:
- `OscillonTwapOracle.priceFromSqrtX96` now takes `decimals0`/`decimals1` and scales the raw ratio into a real dollar-comparable price (`PoolConfig` stores per-pool decimals at registration for this).
- `DeployOscillon.s.sol`'s `_initialSqrtPriceX96` computes the correct decimals-adjusted starting price instead of assuming 1:1 raw parity.
- Liquidity seeding uses `LiquidityAmounts.getLiquidityForAmounts` targeting a real token depth (`SEED_DEPTH` per side) instead of a flat `liquidityDelta` constant that produced near-zero real depth at a skewed price level.

Also fixed alongside the decimals work: `OscillonTwapOracle.readTwapOrSpot` previously judged "TWAP warmed up" by elapsed time alone. With only the synthetic seed observation (tick-cumulative always `0`) and enough wall-clock time passed, it extrapolated a nonsense average tick — invisible for equal-decimal pools initialized near tick 0, but produces an out-of-range `TickMath.InvalidTick` revert for any pool whose real tick sits far from 0. Fixed by also requiring at least 2 real observations before attempting a windowed average.

**K parameter**
`K_STANDARD = 45` used universally; thin-pool tier not yet wired to live liquidity reads.

**Pyth not wired in**
`PythAdapter.sol` is a compiling, tested-in-isolation skeleton — not approved or registered against any deployed pool. See [Oracle Providers](#oracle-providers).

**POC scope**
Static thresholds; one primary oracle source per token (plus TWAP fallback); economic calibration from backtests, not live mainnet stress.

---

## License

MIT
