// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Tests for OscillonHook v3.0:
//   - in-hook TWAP observation ring buffer (OscillonHookTwapTest)
//   - depeg detection + dynamic-fee selection (OscillonHookDepegFeeTest)
//
// Why low-level calls in places: OscillonHook imports PoolId/PoolKey from
// @uniswap/v4-core/... while the v4-core test utils use v4-core/... — these
// remap to physically different files, so the user-defined value types are
// type-incompatible at the Solidity level even though they're identical at
// the ABI level. We use staticcall/call to bridge.

import {Test} from "forge-std/Test.sol";
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

contract OscillonHookTwapTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    uint16 constant OBS_CARDINALITY = 144;
    uint32 constant TWAP_WINDOW = 1800;

    MockERC20 stable0;
    MockERC20 stable1;
    MockV3Aggregator oracle0;
    MockV3Aggregator oracle1;
    ChainlinkOracleAdapter adapter0;
    ChainlinkOracleAdapter adapter1;
    OscillonHook hook;
    PoolKey poolKey;
    bytes32 poolId; // raw PoolId (bytes32) to avoid cross-package type issues

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

        // v3.0 permissions: beforeSwap + afterInitialize + afterSwap.
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

        // Order currencies; init pool with tickSpacing=1 (stable-only guard).
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

        address oForC0 = Currency.unwrap(poolKey.currency0) == address(stable0)
            ? address(adapter0)
            : address(adapter1);
        address oForC1 = Currency.unwrap(poolKey.currency0) == address(stable0)
            ? address(adapter1)
            : address(adapter0);

        // Low-level call: PoolKey type differs across the v4-core / @uniswap/v4-core remap.
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
    }

    // ── _afterInitialize seeds the ring buffer ───────────────────────────────

    function test_afterInitialize_seedsObservationZero() public view {
        assertEq(
            _obsCardinality(),
            uint16(1),
            "cardinality should be 1 after init"
        );
        assertEq(_obsIndex(), uint16(0), "newest index should be 0 after init");

        (uint32 ts, int56 cum, bool initialized) = _observationAt(0);
        assertTrue(initialized, "obs 0 must be initialized");
        assertEq(
            uint256(ts),
            block.timestamp,
            "obs 0 timestamp must equal block.timestamp"
        );
        assertEq(int256(cum), int256(0), "obs 0 tickCumulative must be 0");
    }

    // ── _afterSwap appends a new observation when time has advanced ──────────

    function test_afterSwap_appendsObservation() public {
        uint16 cardBefore = _obsCardinality();
        uint16 idxBefore = _obsIndex();

        vm.warp(block.timestamp + 60);
        _doSmallSwap();

        assertEq(
            _obsCardinality(),
            cardBefore + 1,
            "cardinality should grow by 1"
        );
        assertEq(
            _obsIndex(),
            idxBefore + 1,
            "newest index should advance by 1"
        );

        (uint32 ts, , bool initialized) = _observationAt(idxBefore + 1);
        assertTrue(initialized, "new obs must be initialized");
        assertEq(
            uint256(ts),
            block.timestamp,
            "new obs timestamp should equal now"
        );
    }

    // ── Same-second swaps are deduped (no buffer growth) ─────────────────────

    function test_afterSwap_dedupesSameSecondWrites() public {
        vm.warp(block.timestamp + 60);
        _doSmallSwap();

        uint16 cardAfterFirst = _obsCardinality();
        uint16 idxAfterFirst = _obsIndex();

        // Second swap at the SAME timestamp — should be a no-op for the buffer.
        _doSmallSwap();

        assertEq(
            _obsCardinality(),
            cardAfterFirst,
            "second same-second swap must not add obs"
        );
        assertEq(_obsIndex(), idxAfterFirst, "newest index must not advance");
    }

    // ── Buffer spans the TWAP window after enough activity ───────────────────

    function test_observation_buildsHistoryOver30Min() public {
        // 60 swaps at 35 sec apart → 35 minutes of history (> TWAP_WINDOW).
        for (uint256 i = 0; i < 60; i++) {
            vm.warp(block.timestamp + 35);
            _doSmallSwap();
        }

        uint16 card = _obsCardinality();
        assertEq(card, uint16(61), "init obs + 60 swap obs");

        // Oldest observation must be older than the TWAP window.
        uint16 newestIdx = _obsIndex();
        uint16 oldestIdx = card < OBS_CARDINALITY
            ? 0
            : (newestIdx + 1) % OBS_CARDINALITY;
        (uint32 oldestTs, , ) = _observationAt(oldestIdx);
        assertLe(
            uint256(oldestTs) + TWAP_WINDOW,
            block.timestamp,
            "oldest observation must precede now by >= TWAP_WINDOW"
        );
    }

    // ── getPoolState reports the same warm-up transition ─────────────────────

    function test_getPoolState_twapWarmedUp_falseThenTrue() public {
        (, bool warmedUpCold) = _getPoolStateTwapWarmedUp();
        assertFalse(warmedUpCold, "cold pool: TWAP not warmed up yet");

        // Same 35-min build-up as test_observation_buildsHistoryOver30Min.
        for (uint256 i = 0; i < 60; i++) {
            vm.warp(block.timestamp + 35);
            _doSmallSwap();
        }

        (, bool warmedUpAfter) = _getPoolStateTwapWarmedUp();
        assertTrue(warmedUpAfter, "warmed-up pool: real windowed TWAP now");
    }

    function _getPoolStateTwapWarmedUp()
        internal
        view
        returns (bool registered, bool twapWarmedUp)
    {
        (bool ok, bytes memory data) = address(hook).staticcall(
            abi.encodeWithSignature(
                "getPoolState((address,address,uint24,int24,address))",
                Currency.unwrap(poolKey.currency0),
                Currency.unwrap(poolKey.currency1),
                poolKey.fee,
                poolKey.tickSpacing,
                address(poolKey.hooks)
            )
        );
        require(ok, "getPoolState failed");

        (registered, , , , , , , , , , twapWarmedUp) = abi.decode(
            data,
            (bool, uint256, bool, bool, uint256, bool, bool, bool, uint256, uint256, bool)
        );
        assertTrue(registered);
    }

    // ── Ring buffer wraps and cardinality caps at OBS_CARDINALITY ────────────

    function test_observation_ringBufferWrapsAtCardinality() public {
        // (OBS_CARDINALITY + 10) swaps after init → buffer wraps; newest = 10.
        for (uint256 i = 0; i < uint256(OBS_CARDINALITY) + 10; i++) {
            vm.warp(block.timestamp + 10);
            _doSmallSwap();
        }

        assertEq(
            _obsCardinality(),
            OBS_CARDINALITY,
            "cardinality caps at OBS_CARDINALITY"
        );

        // 1 init write at idx 0, then (OBS_CARDINALITY + 10) appends.
        // newestIdx = (0 + OBS_CARDINALITY + 10) % OBS_CARDINALITY = 10.
        assertEq(_obsIndex(), uint16(10), "newest index wraps correctly");
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    function _doSmallSwap() internal {
        // Tiny size to keep the price near 1.0 and avoid SwapCapExceeded
        // on the rare drain-direction swap.
        oracle0.updateAnswer(int256(1e18));
        oracle1.updateAnswer(int256(1e18));

        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(1e6),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ""
        );
    }

    function _obsCardinality() internal view returns (uint16) {
        (bool ok, bytes memory data) = address(hook).staticcall(
            abi.encodeWithSignature("obsCardinality(bytes32)", poolId)
        );
        require(ok, "obsCardinality call failed");
        return abi.decode(data, (uint16));
    }

    function _obsIndex() internal view returns (uint16) {
        (bool ok, bytes memory data) = address(hook).staticcall(
            abi.encodeWithSignature("obsIndex(bytes32)", poolId)
        );
        require(ok, "obsIndex call failed");
        return abi.decode(data, (uint16));
    }

    function _observationAt(
        uint16 idx
    ) internal view returns (uint32 ts, int56 cum, bool initialized) {
        (bool ok, bytes memory data) = address(hook).staticcall(
            abi.encodeWithSignature("observations(bytes32,uint16)", poolId, idx)
        );
        require(ok, "observations call failed");
        (ts, cum, initialized) = abi.decode(data, (uint32, int56, bool));
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Depeg detection + dynamic-fee selection
// ─────────────────────────────────────────────────────────────────────────────
//
// Fee model (BASE + depeg surcharge):
//   depegBps < SMALL_DEPEG_BPS (3) → BASE_FEE_PIPS (300 = 3 bps)
//   restore-direction (input ABOVE peg) → BASE_FEE_PIPS
//   drain-direction: BASE_FEE_PIPS + hybrid surcharge (piecewise + quadratic)
//
// With K=45:
//     6 bps depeg  → 3 bps base + 1 bps surcharge = 400 pips
//     20 bps depeg → 3 bps base + 6 bps surcharge = 900 pips
//
// Disagreement guard ([CHANGE 4]): if |Chainlink − TWAP| > 20 bps, the hook
// uses the reading closer to $1. In this test environment spot==TWAP==$1, so
// any oracle deviation > 20 bps is overridden to $1. That's why the
// "quadratic fee" tests use exactly 20 bps (boundary case, guard does not
// trigger because the check is strictly `>`).

contract OscillonHookDepegFeeTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    // Mirror the contract's emit signature; canonical type for PoolId is bytes32.
    event DepegDetected(
        bytes32 indexed poolId,
        uint256 depegBps,
        uint24 feeApplied,
        uint256 swapSize,
        bool isDrain,
        bool usingFallback,
        bool twapWarmedUp,
        bool tokenInIsToken0
    );

    uint24 constant BASE_FEE = 300;
    uint24 constant FEE_AT_6_BPS_DRAIN = 400; // 3 bps base + 1 bps surcharge
    uint24 constant FEE_AT_20_BPS = 900; // 3 bps base + 6 bps surcharge
    uint256 constant AMOUNT_IN = 1e15;

    MockERC20 stable0;
    MockERC20 stable1;
    MockV3Aggregator oracle0;
    MockV3Aggregator oracle1; // always represents the "input" oracle in our tests
    ChainlinkOracleAdapter adapter0;
    ChainlinkOracleAdapter adapter1;
    OscillonHook hook;
    PoolKey poolKey;
    bytes32 poolId;

    // Direction that always sells stable1 (so the hook reads oracle1 for input).
    bool sellStable1ZeroForOne;

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

        // Map oracle0/oracle1 to whichever currency they correspond to.
        bool stable0IsCurrency0 = Currency.unwrap(poolKey.currency0) ==
            address(stable0);
        address oForC0 = stable0IsCurrency0
            ? address(adapter0)
            : address(adapter1);
        address oForC1 = stable0IsCurrency0
            ? address(adapter1)
            : address(adapter0);
        sellStable1ZeroForOne = !stable0IsCurrency0; // sell stable1 → input is currency1 unless stable1 sorts first

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
    }

    // ── Healthy pool: no depeg → BASE_FEE ────────────────────────────────────

    function test_swap_NoDepeg_AppliesBaseFee() public {
        vm.expectEmit(true, false, false, true, address(hook));
        emit DepegDetected(poolId, 0, BASE_FEE, AMOUNT_IN, false, false, false, sellStable1ZeroForOne);
        _swap(int256(-int256(AMOUNT_IN)));
    }

    // ── Small drain depeg → hybrid fee (1 bps at 6 bps deviation) ────────────

    function test_swap_SmallDepegDrain_AppliesBasePlusSurcharge() public {
        // 0.9994 → 6 bps deviation; 3 bps base + 1 bps surcharge = 400 pips.
        oracle1.updateAnswer(int256(0.9994e18));
        vm.expectEmit(true, false, false, true, address(hook));
        emit DepegDetected(
            poolId,
            6,
            FEE_AT_6_BPS_DRAIN,
            AMOUNT_IN,
            true,
            false,
            false,
            sellStable1ZeroForOne
        );
        _swap(int256(-int256(AMOUNT_IN)));
    }

    // ── Restore direction (input ABOVE peg) → BASE_FEE ───────────────────────

    function test_swap_RestoreDirection_AppliesBaseFee() public {
        // 1.001 → +10 bps; below the 20-bps disagreement threshold so the
        // guard does not override. Restore direction → BASE_FEE.
        oracle1.updateAnswer(int256(1.001e18));
        vm.expectEmit(true, false, false, true, address(hook));
        emit DepegDetected(poolId, 10, BASE_FEE, AMOUNT_IN, false, false, false, sellStable1ZeroForOne);
        _swap(int256(-int256(AMOUNT_IN)));
    }

    // ── Drain depeg at 20 bps → 3 bps base + 6 bps surcharge = 900 pips ─────

    function test_swap_Drain20bps_AppliesHybridFee() public {
        // 0.998 → 20 bps below peg. Diff vs spot = 20 bps == ORACLE_DISAGREE_BPS,
        // and the guard check is strictly `>`, so Chainlink is used directly.
        oracle1.updateAnswer(int256(0.998e18));
        vm.expectEmit(true, false, false, true, address(hook));
        emit DepegDetected(poolId, 20, FEE_AT_20_BPS, AMOUNT_IN, true, false, false, sellStable1ZeroForOne);
        _swap(int256(-int256(AMOUNT_IN)));
    }

    // ── Disagreement guard: |CL − TWAP| > 20 bps → conservative wins ────────

    function test_disagreementGuard_LargeMismatch_UsesConservative() public {
        // 0.99 → 100 bps depeg on Chainlink, but spot/TWAP = $1.00.
        // |CL − TWAP| = 100 bps > 20 → guard activates → conservative ($1) wins.
        // depegBps = 0, isDrain = false, fee = BASE_FEE.
        oracle1.updateAnswer(int256(0.99e18));
        vm.expectEmit(true, false, false, true, address(hook));
        emit DepegDetected(poolId, 0, BASE_FEE, AMOUNT_IN, false, false, false, sellStable1ZeroForOne);
        _swap(int256(-int256(AMOUNT_IN)));
    }

    // ── Chainlink stale → falls back to TWAP (usingFallback = true) ─────────

    function test_chainlinkStale_FallsBackToTWAP() public {
        // Even with a huge oracle deviation, Chainlink should be IGNORED once
        // it goes stale (>25h since updatedAt) — the catch path uses TWAP,
        // which equals spot ($1) here, so depegBps = 0, fee = BASE_FEE.
        oracle1.updateAnswer(int256(0.95e18));

        // Warp past MAX_ORACLE_AGE (1h) so the staleness check trips. Only
        // the synthetic seed observation exists at this point (no swap has
        // happened yet) — readTwapOrSpot correctly refuses to treat that as
        // "warmed up" regardless of elapsed time, since there's no real
        // trading history to average over yet (see OscillonTwapOracle: card
        // < 2 guard). It falls back to spot, which equals $1 here.
        vm.warp(block.timestamp + 2 hours);
        oracle1.setUpdatedAt(1); // belt-and-braces: force updatedAt firmly stale.

        vm.expectEmit(true, false, false, true, address(hook));
        emit DepegDetected(poolId, 0, BASE_FEE, AMOUNT_IN, false, true, false, sellStable1ZeroForOne); // usingFallback = true, twapWarmedUp = false
        _swap(int256(-int256(AMOUNT_IN)));
    }

    // ── Exact-output during a depeg → reverts ───────────────────────────────

    function test_exactOutput_RevertsDuringDepeg() public {
        oracle1.updateAnswer(int256(0.998e18)); // 20 bps depeg, depegBps >= SMALL_DEPEG_BPS

        // v4 wraps hook reverts in WrappedError(address,bytes4,bytes,bytes4),
        // so we capture the revert payload and assert the inner reason is
        // ExactOutputDisabledDuringDepeg(20).
        bytes4 innerSelector = bytes4(
            keccak256("ExactOutputDisabledDuringDepeg(uint256)")
        );

        bool reverted;
        try this._swapExternal(int256(int256(AMOUNT_IN))) {
            // unreachable
        } catch (bytes memory data) {
            reverted = true;
            // Search for the inner selector inside the wrapped revert data.
            bool found;
            for (uint256 i = 0; i + 4 <= data.length; i++) {
                if (
                    data[i] == innerSelector[0] &&
                    data[i + 1] == innerSelector[1] &&
                    data[i + 2] == innerSelector[2] &&
                    data[i + 3] == innerSelector[3]
                ) {
                    found = true;
                    break;
                }
            }
            assertTrue(found, "expected inner ExactOutputDisabledDuringDepeg");
        }
        assertTrue(reverted, "swap should have reverted");
    }

    function test_getPoolState_returnsBothTokens() public {
        oracle0.updateAnswer(int256(1e18));
        oracle1.updateAnswer(int256(0.9994e18)); // 6 bps on input oracle

        (bool ok, bytes memory data) = address(hook).staticcall(
            abi.encodeWithSignature(
                "getPoolState((address,address,uint24,int24,address))",
                Currency.unwrap(poolKey.currency0),
                Currency.unwrap(poolKey.currency1),
                poolKey.fee,
                poolKey.tickSpacing,
                address(poolKey.hooks)
            )
        );
        require(ok, "getPoolState failed");

        (
            bool registered,
            uint256 depegBps0,
            ,
            ,
            uint256 depegBps1,
            ,
            ,
            ,
            ,
            ,
            bool twapWarmedUp
        ) = abi.decode(
            data,
            (bool, uint256, bool, bool, uint256, bool, bool, bool, uint256, uint256, bool)
        );

        assertTrue(registered);
        // Only two swaps have happened at this point in the test, far short
        // of TWAP_WINDOW (30 min) — the ring buffer hasn't warmed up yet.
        assertFalse(twapWarmedUp);
        bool stable0IsCurrency0 =
            Currency.unwrap(poolKey.currency0) == address(stable0);
        if (stable0IsCurrency0) {
            assertEq(depegBps0, 0);
            assertEq(depegBps1, 6);
        } else {
            assertEq(depegBps0, 6);
            assertEq(depegBps1, 0);
        }
    }

    /// @dev External wrapper so we can use try/catch on the swap.
    function _swapExternal(int256 amountSpecified) external {
        require(msg.sender == address(this), "only self");
        _swap(amountSpecified);
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    function _swap(int256 amountSpecified) internal {
        uint160 sqrtPriceLimitX96 = sellStable1ZeroForOne
            ? (TickMath.MIN_SQRT_PRICE + 1)
            : (TickMath.MAX_SQRT_PRICE - 1);

        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: sellStable1ZeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ""
        );
    }
}

/// @notice Isolated from OscillonHookDepegFeeTest because minAnswer/maxAnswer
/// bounds are cached as immutables at ChainlinkOracleAdapter construction
/// time (mirrors real Chainlink: an aggregator's bounds are fixed for its
/// lifetime — Chainlink deploys a NEW aggregator behind the proxy to change
/// them). The mock must therefore be configured with its floor/ceiling
/// BEFORE the adapter is built, which means this needs its own setUp()
/// rather than reusing the shared fixture.
contract OscillonHookAnswerBoundTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    event DepegDetected(
        bytes32 indexed poolId,
        uint256 depegBps,
        uint24 feeApplied,
        uint256 swapSize,
        bool isDrain,
        bool usingFallback,
        bool twapWarmedUp,
        bool tokenInIsToken0
    );

    uint24 constant BASE_FEE = 300;
    uint256 constant AMOUNT_IN = 1e15;

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
        // oracle1 pinned exactly at a $0.10 floor from the start — the
        // LUNA/UST saturation scenario, not a live depeg that later hits it.
        oracle1 = new MockV3Aggregator(18, int256(0.10e18));
        oracle1.setAnswerBounds(int192(0.10e18), type(int192).max);

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
    }

    // ── Chainlink pinned at its answer floor → falls back to TWAP ───────────

    function test_chainlinkAtAnswerFloor_FallsBackToTWAP() public {
        // updatedAt is fresh (not stale) — only the minAnswer circuit
        // breaker in ChainlinkOracleAdapter can catch this; staleness alone
        // would not, since the aggregator keeps "updating" at its clamp.
        vm.expectEmit(true, false, false, true, address(hook));
        emit DepegDetected(poolId, 0, BASE_FEE, AMOUNT_IN, false, true, false, sellStable1ZeroForOne); // usingFallback = true, twapWarmedUp = false
        _swap(int256(-int256(AMOUNT_IN)));
    }

    function _swap(int256 amountSpecified) internal {
        uint160 sqrtPriceLimitX96 = sellStable1ZeroForOne
            ? (TickMath.MIN_SQRT_PRICE + 1)
            : (TickMath.MAX_SQRT_PRICE - 1);

        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: sellStable1ZeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ""
        );
    }
}

/// @notice Regression test for the decimals-blind TWAP pricing bug: a pool
/// pairing an 18-decimal token (e.g. USDe) against a 6-decimal token (e.g.
/// USDC) was reporting a false ~100% depeg whenever TWAP fallback kicked in,
/// because OscillonTwapOracle.priceFromSqrtX96 converted the raw
/// currency1-per-currency0 unit ratio straight to a "dollar price" with no
/// decimals adjustment — correct only when both tokens share decimals (which
/// every pool before this one happened to). None of the other test fixtures
/// in this file catch this because they all use 18/18 mock pairs.
contract OscillonHookDecimalMismatchTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    event DepegDetected(
        bytes32 indexed poolId,
        uint256 depegBps,
        uint24 feeApplied,
        uint256 swapSize,
        bool isDrain,
        bool usingFallback,
        bool twapWarmedUp,
        bool tokenInIsToken0
    );

    uint24 constant BASE_FEE = 300;
    uint256 constant AMOUNT_IN = 1e15;

    MockERC20 stable18; // 18 decimals, e.g. USDe
    MockERC20 stable6; // 6 decimals, e.g. USDC
    MockV3Aggregator oracle18;
    MockV3Aggregator oracle6;
    ChainlinkOracleAdapter adapter18;
    ChainlinkOracleAdapter adapter6;
    OscillonHook hook;
    PoolKey poolKey;
    bytes32 poolId;
    bool sellStable6ZeroForOne;

    function setUp() public {
        deployFreshManagerAndRouters();

        stable18 = new MockERC20("Ethena USDe", "USDe", 18);
        stable6 = new MockERC20("USD Coin", "USDC", 6);
        stable18.mint(address(this), type(uint128).max);
        stable6.mint(address(this), type(uint128).max);
        stable18.approve(address(swapRouter), type(uint128).max);
        stable6.approve(address(swapRouter), type(uint128).max);
        stable18.approve(address(modifyLiquidityRouter), type(uint128).max);
        stable6.approve(address(modifyLiquidityRouter), type(uint128).max);

        oracle18 = new MockV3Aggregator(18, int256(1e18));
        oracle6 = new MockV3Aggregator(18, int256(1e18));

        adapter18 = new ChainlinkOracleAdapter(
            address(oracle18),
            address(0),
            C.MAX_ORACLE_AGE
        );
        adapter6 = new ChainlinkOracleAdapter(
            address(oracle6),
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

        hook.approveAdapter(address(adapter18));
        hook.approveAdapter(address(adapter6));

        Currency c0 = Currency.wrap(address(stable18));
        Currency c1 = Currency.wrap(address(stable6));
        bool stable18IsCurrency0 = Currency.unwrap(c0) < Currency.unwrap(c1);
        if (!stable18IsCurrency0) (c0, c1) = (c1, c0);

        // Correct initial price for a dollar-neutral pool across a 12-decimal
        // gap: raw ratio (currency1/currency0) must be 10^-12 when the
        // 18-decimal token is currency0, or 10^12 when it's currency1 — NOT
        // SQRT_PRICE_1_1, which is only correct when both decimals match.
        uint160 sqrtPriceX96 = stable18IsCurrency0
            ? uint160(uint256(SQRT_PRICE_1_1) / 1_000_000) // sqrt(1e-12) = 1e-6
            : uint160(uint256(SQRT_PRICE_1_1) * 1_000_000); // sqrt(1e12) = 1e6

        int24 tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        (poolKey, ) = initPool(
            c0,
            c1,
            IHooks(address(hook)),
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            int24(1),
            sqrtPriceX96
        );
        poolId = PoolId.unwrap(poolKey.toId());

        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tick - 120,
                tickUpper: tick + 120,
                liquidityDelta: 1e12,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );

        address oForC0 = stable18IsCurrency0 ? address(adapter18) : address(adapter6);
        address oForC1 = stable18IsCurrency0 ? address(adapter6) : address(adapter18);
        uint8 decForC0 = stable18IsCurrency0 ? 18 : 6;
        uint8 decForC1 = stable18IsCurrency0 ? 6 : 18;
        sellStable6ZeroForOne = !stable18IsCurrency0;

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
                decForC0,
                decForC1
            )
        );
        require(ok, "registerPool failed");
    }

    // ── TWAP fallback on a mismatched-decimals pool must stay near par ──────

    function test_twapFallback_decimalMismatchPool_reportsNearZeroDepeg() public {
        // Force the stable6 (USDC-side) Chainlink adapter stale so pricing
        // falls through to TWAP — this is exactly the path that was
        // reporting a false ~100% depeg before the decimals fix.
        vm.warp(block.timestamp + 2 hours);
        oracle6.setUpdatedAt(1);

        (bool ok, bytes memory data) = address(hook).staticcall(
            abi.encodeWithSignature(
                "getPoolState((address,address,uint24,int24,address))",
                Currency.unwrap(poolKey.currency0),
                Currency.unwrap(poolKey.currency1),
                poolKey.fee,
                poolKey.tickSpacing,
                address(poolKey.hooks)
            )
        );
        require(ok, "getPoolState failed");

        (
            ,
            uint256 depegBps0,
            ,
            ,
            uint256 depegBps1,
            ,
            ,
            ,
            ,
            ,

        ) = abi.decode(
            data,
            (bool, uint256, bool, bool, uint256, bool, bool, bool, uint256, uint256, bool)
        );

        // Both near $1 — before the fix, the mismatched-decimals side would
        // report ~10_000 bps (a false 100% depeg) instead of ~0.
        assertLt(depegBps0, 50, "currency0 depeg should be near zero, not maxed out");
        assertLt(depegBps1, 50, "currency1 depeg should be near zero, not maxed out");
    }
}
