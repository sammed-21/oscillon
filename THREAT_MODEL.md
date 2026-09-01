# Oscillon Threat Model

**Core security principle:** the party that can change the oracle should never have unlimited power over the outcome of a swap.

**What Oscillon actually determines:** not "the oracle says X, therefore X is true," but "is this price trustworthy enough for this action?" — trust degrades gracefully into a fixed base fee, it never invents a price.

**Assumptions this model is scoped to:** a single stable/stable pool (e.g. USDC/USDT) with two Chainlink feeds, deployed on an L2 with a sequencer uptime feed, TVL in the low-to-mid single-digit millions. Re-derive the numbers in §2 if TVL moves an order of magnitude — several defenses (§1.1, §1.4) are only fail-closed at the assumed capital scale.

---

## 1. Adversary model

For each adversary: who they are, what they need, their profit function, and whether the attack is rational today. "Rational today" is judged against `MAX_DEPEG_SWAP_FACTOR = 50_000` (i.e. `50_000 * 10^decimals` per token — [`OscillonConstants.sol:23`](src/constants/OscillonConstants.sol)) and the 0.5%-of-liquidity cap in [`OscillonHook._beforeSwap`](src/OscillonHook.sol#L241-L245), whichever is smaller — this is the hard ceiling on how much any single adversary can drain in one swap regardless of their capital.

### 1.1 Chainlink admin-key compromise

**Who:** whoever holds the private key(s) that update the Chainlink aggregator feeding `ChainlinkOracleAdapter` — not Oscillon's own key, but the upstream feed operator's.
**Capital:** zero on-chain capital; this is a key-compromise, not a market attack. The "cost" is whatever it takes to compromise Chainlink's signing infra, which is out of Oscillon's control and out of scope for this document (see §4).
**Profit function:** push a fabricated low price for one token, let the compromised feed itself trigger `pegBelow = true` in [`OscillonPriceEngine`](src/oracle/OscillonPriceEngine.sol), then drain the pool at the *higher* fee tier is irrelevant to them — they don't pay the fee, they arb the false price against the real market. Profit ≈ pool's available liquidity in the targeted token, capped by §1's swap-size limits.
**Rational today?** Yes, if achievable — this is the highest-value single attack in the model, because Oscillon has no independent second source once you control the feed Chainlink itself reports (see §1.2 for why the TWAP guard only partially helps).
**Current defense and its real strength:** `OscillonDepegMath.pricesDisagree` ([`OscillonDepegMath.sol:30`](src/libraries/OscillonDepegMath.sol)) compares Chainlink against the in-pool 30-minute TWAP and — if they diverge by more than `ORACLE_DISAGREE_BPS = 20` bps ([`OscillonConstants.sol:19`](src/constants/OscillonConstants.sol)) — takes whichever is closer to $1 (`conservativePrice`). This means: **a compromised feed can only move the effective price as far as the TWAP disagreement guard allows before the guard clamps it back toward peg.** A sudden fabricated price (e.g. Chainlink reports $0.50 while the pool is trading at $1.00) gets clamped to ~20 bps off peg, not $0.50 — the disagreement guard is doing real work here, not decorative work. The residual risk is a *slow* fabrication that walks the TWAP along with it over >30 minutes, which the guard cannot catch because both sources agree by construction.
**Gap:** `approveAdapter`/`revokeAdapter`/`updatePoolChainlinkOracle` in [`OscillonHook.sol:485-213`](src/OscillonHook.sol#L196-L213) are plain `onlyOwner` — a single key, zero delay. The THREAT_MODEL previously *claimed* a "timelock 48h + multisig" defense against admin-key compromise; **that defense does not exist in the code.** There is no timelock contract, no multisig check, no delay of any kind on adapter changes. This is a real gap, not a documentation gap — see §3.

### 1.2 Flash-loan / single-block TWAP manipulation

**Who:** any address with flash-loan access to a large pool of the same or a correlated asset.
**Capital:** the notional needed to move this specific pool's spot price meaningfully within one block — bounded above by the swap-size caps in §1, so capital beyond that ceiling buys no additional effect on Oscillon's price read.
**Profit function:** push spot price down within a block, hope the *next* swap prices off a manipulated TWAP tick.
**Rational today?** No — and this is worth stating precisely, not just asserting. `OscillonTwapOracle.readTwapOrSpot` ([`OscillonTwapOracle.sol:54`](src/libraries/OscillonTwapOracle.sol)) only returns spot price directly when the observation buffer hasn't accumulated `TWAP_WINDOW = 1800` seconds (30 min) of history yet ([`OscillonConstants.sol:28`](src/constants/OscillonConstants.sol)); once it has, a single-block price excursion contributes at most `1 tick-second / 1800 tick-seconds` to the 30-minute average — a rounding error, not a usable manipulation. **The real exposure window is pool bootstrap**, before 30 minutes of observations exist: during that window `readTwapOrSpot` returns raw spot, and Chainlink-vs-spot disagreement checks in §1.1 are the only protection. This should be called out operationally: newly registered pools are TWAP-naive for their first 30 minutes. **This is now directly observable, not just an internal implementation detail**: `readTwapOrSpot` returns a `warmedUp` bool alongside the price, surfaced two ways — pool-wide via `OscillonHook.getPoolState()`'s `twapWarmedUp` field (point-in-time query), and per-swap via the `DepegDetected` event's `twapWarmedUp` field (historical, indexable by any off-chain monitor watching swaps as they happen) — so "this pool's fallback pricing was raw spot at swap N" doesn't have to be inferred indirectly or reconstructed after the fact. Note this is reporting-only: the fee curve does **not** change based on this flag (consistent with §5 — fallback pricing already gets the full surcharge, no dampening, regardless of why it's fallback). See `OscillonHookTwapTest.test_getPoolState_twapWarmedUp_falseThenTrue` and the `twapWarmedUp` assertions across `OscillonHookDepegFeeTest`/`OscillonHookAnswerBoundTest`.

### 1.3 Oracle staleness exploited for a stale-price arb

**Who:** any trader monitoring Chainlink update cadence.
**Capital:** normal swap capital, bounded by §1's caps.
**Profit function:** find the window where `block.timestamp > updatedAt + maxAge` is *just* about to trip (or has just tripped) and where TWAP hasn't caught up with a real-world price move yet, then trade against the stale number before staleness forces a TWAP fallback.
**Rational today?** Marginal. `maxAge` defaults to `MAX_ORACLE_AGE = 1 hour` ([`OscillonConstants.sol:18`](src/constants/OscillonConstants.sol)) via `ChainlinkOracleAdapter._readFeed` ([`ChainlinkOracleAdapter.sol:61-77`](src/oracle/adapters/ChainlinkOracleAdapter.sol)). This was tightened from 25h to 1h specifically because most Chainlink USD stable feeds heartbeat every 1h (some every 24h depending on deviation threshold) — 1h keeps the *worst-case* staleness window inside a single intraday depeg event rather than spanning a full day of unmonitored drift. **Derivation, stated plainly: chosen to be ≤ typical feed heartbeat, not derived from a backtest** — this is a reasonable engineering default, not a proven-optimal number. A reviewer should treat this as "sound default, needs per-feed verification before mainnet" rather than "calibrated."

### 1.4 Sustained drain under a real depeg (the "rational bank run")

**Who:** any trader, once a real depeg is public knowledge (e.g. a stablecoin issuer's reserves are in question).
**Capital:** whatever they're willing to lose to exit stale inventory before others do — this is the one adversary whose "attack" is arguably legitimate self-interested behavior, not malice.
**Profit function:** sell the depegging token before its price falls further, extracting from LP inventory at whatever fee Oscillon charges.
**Rational today?** Yes, by design — Oscillon doesn't prevent this, it prices it. `OscillonFeePolicy.hybridFeeBps` ([`OscillonFeePolicy.sol:14-29`](src/libraries/OscillonfeePolicy.sol)) scales the surcharge with depeg magnitude (piecewise below 20 bps, quadratic with `K_STANDARD = 45` above), and `_rollingMultiplier` ([`OscillonHook.sol:373-390`](src/OscillonHook.sol#L373-L390)) adds a 1.10×/1.25×/1.50× multiplier once cumulative drain over the trailing `ROLLING_BLOCKS = 300` blocks (~1 hour at 12s blocks) exceeds 75/150/300 bps of pool liquidity. Fee is hard-capped at `MAX_FEE_PIPS = 5000` (50 bps) regardless of depeg severity — so at extreme depegs (>~50 bps equivalent extraction cost) the attack remains rational; Oscillon compensates LPs, it does not stop the drain. This is the correct design intent per the README ("no pool freeze — severe depeg caps fee at 50 bps; swaps continue"), but it should be stated as a conscious tradeoff, not implied to be a "defense" that resolves the attack.

---

## 2. Defenses — numbers and where they came from

| Defense | Parameter | Source | Derivation |
|---|---|---|---|
| Chainlink staleness | `MAX_ORACLE_AGE = 1 hour` | [`OscillonConstants.sol:18`](src/constants/OscillonConstants.sol), enforced in [`ChainlinkOracleAdapter._readFeed`](src/oracle/adapters/ChainlinkOracleAdapter.sol#L61) | ≤ typical Chainlink USD-stable feed heartbeat. **Not backtested** — treat as a sound default pending per-feed verification. |
| Oracle disagreement guard | `ORACLE_DISAGREE_BPS = 20` | [`OscillonConstants.sol:19`](src/constants/OscillonConstants.sol), [`OscillonDepegMath.pricesDisagree`](src/libraries/OscillonDepegMath.sol#L30) | Roughly the noise band a healthy Chainlink feed and a 30-min TWAP can disagree by under normal volatility without either being "wrong." **Not backtested against real feed/TWAP divergence data.** |
| TWAP window | `TWAP_WINDOW = 1800s` (30 min) | [`OscillonConstants.sol:28`](src/constants/OscillonConstants.sol), [`OscillonTwapOracle.readTwapOrSpot`](src/libraries/OscillonTwapOracle.sol#L54) | Standard Uniswap TWAP convention; long enough that a single flash-loaned block contributes a negligible fraction of the average (see §1.2). |
| Sequencer grace period | `SEQUENCER_GRACE_PERIOD = 3600s` (1h) | [`OscillonConstants.sol:20`](src/constants/OscillonConstants.sol), [`ChainlinkOracleAdapter._assertSequencerUp`](src/oracle/adapters/ChainlinkOracleAdapter.sol#L51) | Chainlink's own documented recommendation for L2 sequencer-uptime grace periods. |
| Per-swap drain cap | `min(MAX_DEPEG_SWAP_FACTOR * 10^decimals, 0.5% of pool liquidity)` | [`OscillonConstants.sol:23`](src/constants/OscillonConstants.sol), [`OscillonHook._beforeSwap`](src/OscillonHook.sol#L241-L245) | `MAX_DEPEG_SWAP_FACTOR = 50_000` is an absolute per-token ceiling; the 0.5%-of-liquidity term is the binding constraint for any pool under ~$10M TVL. **No documented derivation for either number — flag for calibration against target launch TVL.** |
| Rolling drain multiplier | 100% / 110% / 125% / 150% at 0 / 75 / 150 / 300 bps of trailing drain | [`OscillonFeePolicy.rollingMultiplier`](src/libraries/OscillonfeePolicy.sol#L71-L78), window = `ROLLING_BLOCKS = 300` blocks | **No documented derivation** — thresholds and multipliers appear hand-picked, not fit to the backtest data referenced in the README. |
| Fee ceiling | `MAX_FEE_PIPS = 5000` (50 bps) | [`OscillonConstants.sol:8`](src/constants/OscillonConstants.sol) | Matches the backtest scenarios in the README (USDC March-2023 depeg reached this cap). Chosen as "enough to meaningfully compensate LPs without becoming an effective trading halt." |
| Exact-output block | Triggers at `depegBps >= SMALL_DEPEG_BPS = 3` | [`OscillonConstants.sol:12`](src/constants/OscillonConstants.sol), [`OscillonHook._beforeSwap`](src/OscillonHook.sol#L236-L238) | Same threshold that switches the fee curve from flat base fee to the dynamic surcharge — i.e., "the moment the surcharge exists at all, a trader can no longer force an exact output through it." Internally consistent, not independently derived. |
| Value bound on feed reads | `answer <= 0` reverts, **plus** `answer <= minAnswer \|\| answer >= maxAnswer` reverts | [`ChainlinkOracleAdapter._readFeed`](src/oracle/adapters/ChainlinkOracleAdapter.sol) | `minAnswer`/`maxAnswer` are read from the underlying Chainlink aggregator itself (resolved through the `EACAggregatorProxy.aggregator()` indirection if `feed` is a proxy — see `_tryFetchBounds`) and cached as `immutable` at adapter construction, mirroring the fact that a live Chainlink aggregator's bounds don't change — Chainlink deploys a *new* aggregator behind the proxy when bounds need to move (exactly what happened after the May 2022 LUNA/UST collapse, where feeds kept reporting their configured floor long after the real price fell further). If neither the feed nor its underlying aggregator exposes these functions, `boundsKnown = false` and the check is skipped rather than reverting on every read. **This closes the previous gap** — see [`test/ChainlinkOracleAdapter.t.sol`](test/ChainlinkOracleAdapter.t.sol) and [`OscillonHookAnswerBoundTest`](test/OscillonHook.t.sol) for the saturation-at-floor scenario proven end-to-end (adapter reverts → `OscillonPriceEngine` falls through to TWAP, same path as staleness). Residual gap: no *deviation-from-last-answer* check (a single-round jump within `[minAnswer, maxAnswer]` is still trusted outright) — that would need a different mechanism (e.g. max-bps-move-per-round) and is not implemented. |

---

## 3. The timelock/multisig gap — modeled as its own state, not a solved problem

**This is the single most important correction to the previous version of this document.**

The prior table listed "timelock 48h + multisign" as the defense against oracle admin-key compromise. **No timelock or multisig exists anywhere in this codebase.** `owner` is a single address ([`OscillonHook.sol:83`](src/OscillonHook.sol#L83)), set at construction, transferable via a single `onlyOwner` call with zero delay ([`OscillonHook.transferOwnership`](src/OscillonHook.sol#L507-L511)). `approveAdapter`, `revokeAdapter`, `updatePoolChainlinkOracle`, and `registerPool` are all instant, single-key, `onlyOwner` operations.

Even if a timelock is added later (recommended), it must be modeled as a new state with its own risks — not treated as the resolution:

- **During the delay window, is the old (possibly-compromised) adapter still live?** If yes, a compromised owner key can still call `revokeAdapter` on the *good* adapter instantly (revocation has no reason to be timelocked the same way approval does) — asymmetric timelocking needs to be a deliberate design choice, not an oversight.
- **Can LPs exit during the window?** Yes today — "Liquidity add/remove is unrestricted (no hook on LP operations)" per the README — so a timelocked malicious adapter swap gives LPs a 48h warning to withdraw, which is good, but also means the *last* LPs left holding the pool when the malicious update lands bear concentrated risk. That's a distributional risk, not a solved one.
- **What can the compromised key still do in 48h with no timelock on it?** `setProtocolTreasury` and `transferOwnership` would need to be in scope for the same delay, or a compromised key simply redirects protocol fee collection or hands ownership to itself permanently while the "protected" adapter change sits in a queue nobody is watching.
- **Is there a pause/cancel mechanism for a queued malicious change once detected?** Not currently — a timelock with no cancel path is a guaranteed-delayed attack, not a prevented one.

**Recommendation, stated as a gap, not a claim:** before "timelock + multisig" reappears in this table as a defense, it needs: (a) actual implementation, (b) explicit statement of which functions are covered vs. instant, (c) a cancel/veto path, and (d) the LP-exit-window tradeoff above stated as accepted risk.

---

## 4. Explicitly out of scope

This document covers **oracle-input risk to the fee mechanism only**. It does not cover:

- **MEV at the swap-execution layer** — sandwich attacks, JIT liquidity around large swaps, backrunning a fee-changing swap to front the *next* trader at the new rate. Oscillon's dynamic fee is itself a new MEV surface (a searcher can observe a pending depeg-triggering swap and front-run to capture the rate change) — this needs its own analysis and is not attempted here.
- **Chainlink infrastructure security** — key management, signer set compromise, or aggregator contract bugs upstream of `ChainlinkOracleAdapter`. Oscillon treats Chainlink as a trust-minimized-but-not-trustless input; compromise of Chainlink itself is assumed possible (§1.1) but its root causes are out of scope.
- **v4 core / PoolManager security** — reentrancy, accounting bugs, or settlement risk in Uniswap v4 itself. `BaseHook` restricts callbacks to `PoolManager`; beyond that boundary this is Uniswap's threat surface, not Oscillon's.
- **Governance/upgrade risk beyond §3** — key custody practices, multisig signer selection, or off-chain incident response process.
- **Economic calibration beyond "not backtested" flags** — several constants in §2 are marked as un-derived; closing that gap requires running the existing backtest harness against candidate parameter sets, which has not been done for the rolling-multiplier thresholds or the swap-cap constants specifically (only the fee-curve shape itself was backtested, per the README).
- **`surplusAccrued`/`protocolAccrued` accounting** — tracked in state but not connected to real v4 fee settlement (README, "Known Limitations"); this is a correctness gap, not a security one, but it means any security review of fee *collection* (as opposed to fee *pricing*) is premature.

---

## 5. Fail-closed behavior (unchanged from original intent, restated precisely)

When Chainlink read fails (stale, invalid, incomplete round, or sequencer down) for the token being sold, `OscillonPriceEngine.getSellTokenPrice` ([`OscillonPriceEngine.sol:15`](src/oracle/OscillonPriceEngine.sol)) falls through to the pool TWAP with `usingFallback = true` — no revert, no invented price, no pool freeze. As of the current fee policy, fallback pricing receives the **same** surcharge as primary pricing (no dampening — see the `testFuzz_fallbackNeverCheaperThanPrimary` invariant in `test/OscillonInvariants.t.sol`), on the reasoning that oracle uncertainty should never make draining the pool cheaper. This is "base fee floor, TWAP-priced surcharge on top" rather than "no price invention" being interpreted as "flat fee only" — worth being precise about, since the two read differently to a reviewer.

---

## 6. Invariant tests

`test/OscillonInvariants.t.sol` encodes the claims above directly:

- `OscillonFeePolicyInvariants` — pure fuzz tests: total fee never exceeds `MAX_FEE_PIPS`, fee curve is monotonic in depeg magnitude, rolling multiplier is monotonic in drain pressure, TWAP-fallback pricing is never cheaper than primary pricing, and the disagreement guard always selects the price closer to peg.
- `OscillonHookInvariants` — a stateful invariant campaign against the deployed hook: randomized oracle prices, swap sizes, directions, and block/time advances across a long call sequence, asserting the applied fee (read from real `DepegDetected` events, not simulated) stays within `[BASE_FEE_PIPS, MAX_FEE_PIPS]` even as rolling-drain and restore-window state accumulate — the class of bug unit tests can't catch because they only exercise one swap at a time.

`test/ChainlinkOracleAdapter.t.sol` and `OscillonHookAnswerBoundTest` (in `test/OscillonHook.t.sol`) prove the minAnswer/maxAnswer circuit breaker in §2 end-to-end: an aggregator saturated at its floor is rejected by the adapter and the hook falls through to TWAP pricing, the same path staleness uses.

This is a partial set — it proves the fee-bound claims in §2 and the answer-bound claim in §2, not the rest of the oracle-cascade claims in §1 (those still rely on the deterministic unit tests in `test/OscillonHook.t.sol`) or anything in §3/§4.
