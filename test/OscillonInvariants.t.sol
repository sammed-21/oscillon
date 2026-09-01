// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Invariant / property tests encoding the fail-closed guarantees claimed in
// THREAT_MODEL.md. Two layers:
//   1. Pure fuzz tests on the fee-curve math (OscillonFeePolicyInvariants) —
//      no state, no oracle, just: does the formula ever violate its own cap?
//   2. A stateful invariant campaign against the deployed hook
//      (OscillonHookInvariants) — random oracle prices, random swap sizes,
//      random block/time advances, across many calls in sequence, checking
//      that fee bounds hold even as rolling-drain and restore-window state
//      accumulates across swaps (exactly what single-shot unit tests miss).

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Deployers} from "v4-core-test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {MockV3Aggregator} from "./mock/MockV3Aggregator.sol";
import {OscillonHook} from "../src/OscillonHook.sol";
import {
    ChainlinkOracleAdapter
} from "../src/oracle/adapters/ChainlinkOracleAdapter.sol";
import {OscillonConstants as C} from "../src/constants/OscillonConstants.sol";
import {OscillonFeePolicy} from "../src/libraries/OscillonFeePolicy.sol";
import {OscillonDepegMath} from "../src/libraries/OscillonDepegMath.sol";

// ─────────────────────────────────────────────────────────────────────────
// Layer 1: pure math invariants — no deployment, no oracle, microsecond runs.
// ─────────────────────────────────────────────────────────────────────────

contract OscillonFeePolicyInvariants is Test {
    // Invariant: total fee (base + surcharge) never exceeds MAX_FEE_PIPS,
    // for any depeg magnitude and any rolling-drain multiplier the policy
    // can produce. This is the on-chain equivalent of "the hook cannot
    // charge a trader more than the documented 50 bps ceiling."
    function testFuzz_totalFeeNeverExceedsCap(
        uint256 devBps,
        uint256 rollingMultSeed
    ) public pure {
        devBps = bound(devBps, 0, 1_000_000); // up to 100x depeg, far past any realistic scenario
        // rollingMultiplier() only ever returns 100/110/125/150 — fuzz the
        // drainPctBps input that selects it instead of faking the multiplier.
        uint256 drainPctBps = bound(rollingMultSeed, 0, 1_000_000);
        uint256 mult = OscillonFeePolicy.rollingMultiplier(drainPctBps);

        uint256 feeBps = OscillonFeePolicy.hybridFeeBps(devBps, C.K_STANDARD);
        uint24 surcharge = OscillonFeePolicy.depegSurchargePips(
            feeBps,
            false,
            devBps,
            mult
        );
        uint24 total = OscillonFeePolicy.totalFeePips(
            C.BASE_FEE_PIPS,
            surcharge
        );

        assertLe(total, C.MAX_FEE_PIPS);
    }

    // Invariant: the fee curve is monotonically non-decreasing in depeg
    // magnitude. A bigger depeg must never produce a *cheaper* drain swap —
    // that would invert the economic incentive the whole hook exists for.
    function testFuzz_hybridFee_monotonicInDepeg(
        uint256 devBpsLow,
        uint256 devBpsHigh
    ) public pure {
        devBpsLow = bound(devBpsLow, 0, 1_000_000);
        devBpsHigh = bound(devBpsHigh, devBpsLow, 1_000_000);

        uint256 feeLow = OscillonFeePolicy.hybridFeeBps(devBpsLow, C.K_STANDARD);
        uint256 feeHigh = OscillonFeePolicy.hybridFeeBps(devBpsHigh, C.K_STANDARD);

        assertGe(feeHigh, feeLow);
    }

    // Invariant: the rolling-drain multiplier is monotonically non-decreasing
    // in cumulative drain pressure — sustained draining must never become
    // cheaper as it continues.
    function testFuzz_rollingMultiplier_monotonicInDrainPressure(
        uint256 lowPct,
        uint256 highPct
    ) public pure {
        lowPct = bound(lowPct, 0, 1_000_000);
        highPct = bound(highPct, lowPct, 1_000_000);

        assertGe(
            OscillonFeePolicy.rollingMultiplier(highPct),
            OscillonFeePolicy.rollingMultiplier(lowPct)
        );
    }

    // Invariant: removing the TWAP-fallback dampening (this branch) means
    // fallback and non-fallback pricing must produce IDENTICAL surcharge for
    // the same feeBps/mult — locking in the "no cheaper drains when the
    // oracle is uncertain" decision so a future edit can't silently
    // reintroduce the discount.
    function testFuzz_fallbackNeverCheaperThanPrimary(
        uint256 feeBps,
        uint256 devBps,
        uint256 mult
    ) public pure {
        feeBps = bound(feeBps, 0, 50);
        devBps = bound(devBps, 0, 1_000_000);
        mult = bound(mult, 100, 150);

        uint24 withFallback = OscillonFeePolicy.depegSurchargePips(
            feeBps,
            true,
            devBps,
            mult
        );
        uint24 withoutFallback = OscillonFeePolicy.depegSurchargePips(
            feeBps,
            false,
            devBps,
            mult
        );

        assertEq(withFallback, withoutFallback);
    }

    // Invariant: the disagreement guard always resolves to the price closer
    // to (or equal to) $1 — it must never be possible for conservativePrice
    // to select the MORE deviated of the two inputs.
    function testFuzz_conservativePrice_picksCloserToPeg(
        uint256 priceA,
        uint256 priceB
    ) public pure {
        priceA = bound(priceA, 1e15, 1e21);
        priceB = bound(priceB, 1e15, 1e21);

        uint256 result = OscillonDepegMath.conservativePrice(priceA, priceB);
        uint256 devResult = OscillonDepegMath.deviationFromPeg(result);

        assertLe(devResult, OscillonDepegMath.deviationFromPeg(priceA));
        assertLe(devResult, OscillonDepegMath.deviationFromPeg(priceB));
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Layer 2: stateful invariant campaign against the deployed hook.
// ─────────────────────────────────────────────────────────────────────────

contract OscillonHookInvariants is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    event DepegDetected(
        PoolId indexed poolId,
        uint256 depegBps,
        uint24 feeApplied,
        uint256 swapSize,
        bool isDrain,
        bool usingFallback,
        bool twapWarmedUp
    );

    uint256 constant MIN_AMOUNT = 1e12;
    uint256 constant MAX_AMOUNT = 1e16;

    MockERC20 stable0;
    MockERC20 stable1;
    MockV3Aggregator oracle0;
    MockV3Aggregator oracle1;
    ChainlinkOracleAdapter adapter0;
    ChainlinkOracleAdapter adapter1;
    OscillonHook hook;
    PoolKey poolKey;
    bytes32 poolId;
    bool sellStable1ZeroForOne;

    // Ghost state, updated only from real DepegDetected logs emitted by swaps
    // that actually executed — reverted attempts (e.g. swap-cap exceeded)
    // are not violations, they're the cap working.
    uint24 public maxFeeSeen;
    uint24 public minFeeSeen = type(uint24).max;
    uint256 public feeEventsSeen;
    uint256 public callsAttempted;

    // Foundry checks every invariant_ once immediately after setUp(), before
    // any handler call has run — a strict "we saw an event" assertion would
    // fail trivially at that pristine t=0 state. Gate on a small warm-up so
    // the check only applies once the campaign has actually had a chance to
    // swap and capture logs.
    uint256 constant WARMUP_CALLS = 20;

    function setUp() public {
        deployFreshManagerAndRouters();

        stable0 = new MockERC20("USD Coin", "USDC", 18);
        stable1 = new MockERC20("Tether", "USDT", 18);
        stable0.mint(address(this), type(uint128).max);
        stable1.mint(address(this), type(uint128).max);
        stable0.approve(address(swapRouter), type(uint128).max);
        stable1.approve(address(swapRouter), type(uint128).max);
        stable0.approve(address(modifyLiquidityRouter), type(uint128).max);
        stable1.approve(address(modifyLiquidityRouter), type(uint128).max);

        oracle0 = new MockV3Aggregator(18, int256(1e18));
        oracle1 = new MockV3Aggregator(18, int256(1e18));
        adapter0 = new ChainlinkOracleAdapter(
            address(oracle0),
            address(0),
            C.MAX_ORACLE_AGE
        );
        adapter1 = new ChainlinkOracleAdapter(
            address(oracle1),
            address(0),
            C.MAX_ORACLE_AGE
        );

        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG |
                Hooks.AFTER_INITIALIZE_FLAG |
                Hooks.AFTER_SWAP_FLAG
        );
        deployCodeTo(
            "OscillonHook",
            abi.encode(manager, address(this)),
            address(flags)
        );
        hook = OscillonHook(payable(address(flags)));

        hook.approveAdapter(address(adapter0));
        hook.approveAdapter(address(adapter1));

        Currency c0 = Currency.wrap(address(stable0));
        Currency c1 = Currency.wrap(address(stable1));
        if (Currency.unwrap(c0) > Currency.unwrap(c1)) (c0, c1) = (c1, c0);

        (poolKey, ) = initPool(
            c0,
            c1,
            IHooks(address(hook)),
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            int24(1),
            SQRT_PRICE_1_1
        );
        poolId = PoolId.unwrap(poolKey.toId());

        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            LIQUIDITY_PARAMS,
            ZERO_BYTES
        );

        bool stable0IsCurrency0 = Currency.unwrap(poolKey.currency0) ==
            address(stable0);
        address oForC0 = stable0IsCurrency0
            ? address(adapter0)
            : address(adapter1);
        address oForC1 = stable0IsCurrency0
            ? address(adapter1)
            : address(adapter0);
        sellStable1ZeroForOne = !stable0IsCurrency0;

        (bool ok, ) = address(hook).call(
            abi.encodeWithSignature(
                "registerPool((address,address,uint24,int24,address),address,address,uint8,uint8)",
                Currency.unwrap(poolKey.currency0),
                Currency.unwrap(poolKey.currency1),
                poolKey.fee,
                poolKey.tickSpacing,
                address(poolKey.hooks),
                oForC0,
                oForC1,
                uint8(18),
                uint8(18)
            )
        );
        require(ok, "registerPool failed");

        // Restrict the fuzzer to this contract's public handler function
        // (fuzz_swap) so it doesn't waste runs calling view/admin functions.
        targetContract(address(this));
    }

    /// @dev Handler function the invariant fuzzer calls repeatedly with
    /// random inputs, advancing block/time between calls so rolling-drain
    /// windows and Chainlink staleness both get exercised across a run —
    /// not just a single isolated swap.
    function fuzz_swap(
        uint256 priceSeed,
        uint256 amountSeed,
        uint256 blockSeed,
        uint256 timeSeed,
        bool drainDirection
    ) public {
        callsAttempted++;
        vm.roll(block.number + bound(blockSeed, 0, 400));
        vm.warp(block.timestamp + bound(timeSeed, 0, 2 hours));

        // +/-20% covers everything from a healthy peg through the fee curve's
        // full 50-bps-cap range and past MAX_ORACLE_AGE-relevant magnitudes.
        int256 price = int256(bound(priceSeed, 0.80e18, 1.20e18));
        oracle1.updateAnswer(price);

        uint256 amount = bound(amountSeed, MIN_AMOUNT, MAX_AMOUNT);
        bool zeroForOne = drainDirection
            ? sellStable1ZeroForOne
            : !sellStable1ZeroForOne;
        uint160 sqrtPriceLimitX96 = zeroForOne
            ? (TickMath.MIN_SQRT_PRICE + 1)
            : (TickMath.MAX_SQRT_PRICE - 1);

        vm.recordLogs();
        try
            swapRouter.swap(
                poolKey,
                IPoolManager.SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -int256(amount),
                    sqrtPriceLimitX96: sqrtPriceLimitX96
                }),
                PoolSwapTest.TestSettings({
                    takeClaims: false,
                    settleUsingBurn: false
                }),
                ""
            )
        {
            _captureFee();
        } catch {
            // Reverted (e.g. SwapCapExceeded) — the cap doing its job, not a
            // violation. Nothing to record.
        }
    }

    function _captureFee() internal {
        bytes32 topic0 = keccak256(
            "DepegDetected(bytes32,uint256,uint24,uint256,bool,bool,bool)"
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(hook)) continue;
            if (logs[i].topics.length == 0 || logs[i].topics[0] != topic0) {
                continue;
            }
            (, uint24 feeApplied, , , , ) = abi.decode(
                logs[i].data,
                (uint256, uint24, uint256, bool, bool, bool)
            );
            if (feeApplied > maxFeeSeen) maxFeeSeen = feeApplied;
            if (feeApplied < minFeeSeen) minFeeSeen = feeApplied;
            feeEventsSeen++;
        }
    }

    // ── Invariants, checked after every handler call in the campaign ───────

    /// The fee actually applied on-chain, across an arbitrarily long random
    /// sequence of swaps with accumulating rolling-drain state, never
    /// exceeds the documented 50 bps cap.
    function invariant_appliedFeeNeverExceedsCap() public view {
        assertLe(maxFeeSeen, C.MAX_FEE_PIPS);
    }

    /// The fee actually applied never drops below the 3 bps base — there is
    /// no code path that waives the base fee entirely.
    function invariant_appliedFeeNeverBelowBase() public view {
        if (callsAttempted < WARMUP_CALLS) return; // let the campaign warm up
        assertGe(minFeeSeen, C.BASE_FEE_PIPS);
    }

    /// Self-check: fails loudly if the log-matching above silently matched
    /// nothing (e.g. a signature typo), which would make the two invariants
    /// above vacuously true instead of actually proven. Gated by
    /// WARMUP_CALLS so it doesn't fail on the pristine pre-call state that
    /// Foundry checks immediately after setUp().
    function invariant_handlerActuallyObservedFeeEvents() public view {
        if (callsAttempted < WARMUP_CALLS) return;
        assertGt(feeEventsSeen, 0);
    }
}
