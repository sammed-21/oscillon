// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {Deployers} from "v4-core-test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {LiquidityAmounts} from "v4-core-test/utils/LiquidityAmounts.sol";
import {MockV3Aggregator} from "./mock/MockV3Aggregator.sol";

import {ERC1155TokenReceiver} from "solmate/src/tokens/ERC1155.sol";

import {OscillonHook} from "../src/OscillonHook.sol";

contract TestOscillonHook is Test, Deployers {
    // two configured stables for the hook (e.g. USDC/USDT)
    MockERC20 stable0;
    MockERC20 stable1;
    Currency stable0Currency;
    Currency stable1Currency;

    MockV3Aggregator oracle0;
    MockV3Aggregator oracle1;
    OscillonHook hook;

    // Match OscillonHook's event signature so `vm.expectEmit` can validate it.
    event DepegDetected(uint256 depegBps, uint24 fee, uint256 swapSize);

    uint256 constant AMOUNT_IN = 1e15;

    // Fee schedule in OscillonHook.sol (100 pips ~= 1 bps, etc.)
    uint24 constant BASE_FEE_PIPS = 100;
    uint24 constant SMALL_FEE_PIPS = 800;
    uint24 constant DRAIN_FEE_PIPS = 2800;
    uint24 constant RESTORE_FEE_PIPS = 30;

    function setUp() public {
        deployFreshManagerAndRouters();

        // Deploy stable tokens (mocked as 18 decimals for tests).
        stable0 = new MockERC20("USD Coin", "USDC", 18);
        stable1 = new MockERC20("Tether", "USDT", 18);
        stable0Currency = Currency.wrap(address(stable0));
        stable1Currency = Currency.wrap(address(stable1));

        stable0.mint(address(this), type(uint128).max);
        stable1.mint(address(this), type(uint128).max);

        // Mint approvals for routers (spender is the router contracts).
        stable0.approve(address(swapRouter), type(uint128).max);
        stable1.approve(address(swapRouter), type(uint128).max);
        stable0.approve(address(modifyLiquidityRouter), type(uint128).max);
        stable1.approve(address(modifyLiquidityRouter), type(uint128).max);

        // Deploy two oracles (1e18 = $1).
        oracle0 = new MockV3Aggregator(18, int256(1e18));
        oracle1 = new MockV3Aggregator(18, int256(1e18));

        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG);

        // Pass: manager, oracle0, stable0, stableDecimals0, oracle1, stable1, stableDecimals1
        bytes memory constructorArgs = abi.encode(
            manager,
            oracle0,
            address(stable0),
            uint8(18),
            oracle1,
            address(stable1),
            uint8(18)
        );
        deployCodeTo("OscillonHook", constructorArgs, address(flags));
        hook = OscillonHook(payable(address(flags)));

        // Pool must be stable/stable, and PoolManager requires currency0 < currency1.
        Currency c0 = stable0Currency;
        Currency c1 = stable1Currency;
        if (Currency.unwrap(c0) > Currency.unwrap(c1)) {
            (c0, c1) = (c1, c0);
        }

        (key, ) = initPool(
            c0,
            c1,
            IHooks(address(hook)),
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            SQRT_PRICE_1_1
        );

        // Add liquidity using the default test parameters from Deployers.
        modifyLiquidityRouter.modifyLiquidity(
            key,
            LIQUIDITY_PARAMS,
            ZERO_BYTES
        );
    }

    function _sellStable1IntoPool() internal {
        bool stable1IsCurrency0 = Currency.unwrap(key.currency0) ==
            Currency.unwrap(stable1Currency);
        bool zeroForOne = stable1IsCurrency0; // input token is currency0
        uint160 sqrtPriceLimitX96 = zeroForOne
            ? (TickMath.MIN_SQRT_PRICE + 1)
            : (TickMath.MAX_SQRT_PRICE - 1);

        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(AMOUNT_IN),
                sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ""
        );
    }

    function _sellStable0IntoPool() internal {
        bool stable0IsCurrency0 = Currency.unwrap(key.currency0) ==
            Currency.unwrap(stable0Currency);
        bool zeroForOne = stable0IsCurrency0; // input token is currency0
        uint160 sqrtPriceLimitX96 = zeroForOne
            ? (TickMath.MIN_SQRT_PRICE + 1)
            : (TickMath.MAX_SQRT_PRICE - 1);

        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(AMOUNT_IN),
                sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ""
        );
    }

    function test_beforeSwap_AppliesPolicyLadder_WhenUSDTDepegs() public {
        // Scenario 1 — healthy pool (depeg = 0 => base fee)
        oracle0.updateAnswer(int256(1e18));
        oracle1.updateAnswer(int256(1e18));

        vm.expectEmit(true, true, true, true, address(hook));
        emit DepegDetected(0, BASE_FEE_PIPS, AMOUNT_IN);
        _sellStable1IntoPool();

        // Scenario 2 — small depeg: 7 bps => small fee
        // oraclePrice = 1e18 * (1 - 7/10000) = 0.9993e18
        oracle1.updateAnswer(999300000000000000);

        vm.expectEmit(true, true, true, true, address(hook));
        emit DepegDetected(7, SMALL_FEE_PIPS, AMOUNT_IN);
        _sellStable1IntoPool();

        // Scenario 3 — drain tier: 20 bps => drain fee
        // oraclePrice = 1e18 * (1 - 20/10000) = 0.998e18
        oracle1.updateAnswer(998000000000000000);

        vm.expectEmit(true, true, true, true, address(hook));
        emit DepegDetected(20, DRAIN_FEE_PIPS, AMOUNT_IN);
        _sellStable1IntoPool();

        // Scenario 4 — restore: back to peg => restore fee within restore window
        vm.warp(block.timestamp + 30 minutes);
        oracle1.updateAnswer(int256(1e18));

        vm.expectEmit(true, true, true, true, address(hook));
        emit DepegDetected(0, RESTORE_FEE_PIPS, AMOUNT_IN);
        _sellStable1IntoPool();

        // Scenario 5 — severe depeg: 60 bps => circuit breaker freeze (revert)
        oracle1.updateAnswer(994000000000000000); // 0.994e18

        vm.expectRevert();
        _sellStable1IntoPool();
    }

    function test_beforeSwap_AppliesPolicyLadder_WhenUSDCDepegs() public {
        // Scenario 1 — healthy pool (base fee)
        oracle0.updateAnswer(int256(1e18));
        oracle1.updateAnswer(int256(1e18));

        vm.expectEmit(true, true, true, true, address(hook));
        emit DepegDetected(0, BASE_FEE_PIPS, AMOUNT_IN);
        _sellStable0IntoPool();

        // Scenario 2 — small depeg for stable0 (7 bps => small fee)
        oracle0.updateAnswer(999300000000000000);
        vm.expectEmit(true, true, true, true, address(hook));
        emit DepegDetected(7, SMALL_FEE_PIPS, AMOUNT_IN);
        _sellStable0IntoPool();

        // Scenario 3 — drain tier for stable0 (20 bps => drain fee)
        oracle0.updateAnswer(998000000000000000);
        vm.expectEmit(true, true, true, true, address(hook));
        emit DepegDetected(20, DRAIN_FEE_PIPS, AMOUNT_IN);
        _sellStable0IntoPool();

        // Scenario 4 — restore for stable0 => restore fee
        vm.warp(block.timestamp + 30 minutes);
        oracle0.updateAnswer(int256(1e18));
        vm.expectEmit(true, true, true, true, address(hook));
        emit DepegDetected(0, RESTORE_FEE_PIPS, AMOUNT_IN);
        _sellStable0IntoPool();

        // Scenario 5 — severe depeg (60 bps) => circuit breaker freeze (revert)
        oracle0.updateAnswer(994000000000000000);
        vm.expectRevert();
        _sellStable0IntoPool();
    }

    function test_beforeSwap_Reverts_WhenCallerIsNotPoolManager() public {
        bool zeroForOne = true;
        uint160 sqrtPriceLimitX96 = TickMath.MIN_SQRT_PRICE + 1;
        vm.expectRevert();
        IHooks(address(hook)).beforeSwap(
            address(this),
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(AMOUNT_IN),
                sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            ""
        );
    }

    function test_beforeSwap_Reverts_WhenInputStableIsAbovePegByFreezeThreshold()
        public
    {
        // Input stable = stable1 path.
        // 1.006e18 => +60 bps above peg => should freeze too.
        oracle1.updateAnswer(1006000000000000000);

        vm.expectRevert();
        _sellStable1IntoPool();
    }

    function test_beforeSwap_Reverts_WhenExactOutputExceedsDeepDepegCap()
        public
    {
        // Deep depeg below peg so the cap path is active.
        oracle1.updateAnswer(998000000000000000); // 20 bps below peg

        bool stable1IsCurrency0 = Currency.unwrap(key.currency0) ==
            Currency.unwrap(stable1Currency);
        bool zeroForOne = stable1IsCurrency0; // input token is currency0
        uint160 sqrtPriceLimitX96 = zeroForOne
            ? (TickMath.MIN_SQRT_PRICE + 1)
            : (TickMath.MAX_SQRT_PRICE - 1);

        // exact-output path: amountSpecified > 0
        uint256 tooMuchOut = 10_001e18;
        vm.expectRevert();
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: int256(tooMuchOut),
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
