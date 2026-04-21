// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

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
import {console} from "forge-std/console.sol";

contract OscillonHookBasicTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    event DepegDetected(
        PoolId indexed poolId,
        uint256 depegBps,
        uint24 feeApplied,
        uint256 swapSize,
        bool isDrain
    );

    uint256 constant AMOUNT_IN = 1e15;
    uint24 constant MAX_FEE_PIPS = 5000; // severe depeg fee cap in hook

    MockERC20 stable0;
    MockERC20 stable1;
    Currency stable0Currency;
    Currency stable1Currency;
    MockV3Aggregator oracle0;
    MockV3Aggregator oracle1;
    OscillonHook hook;
    PoolKey poolKey;

    function setUp() public {
        deployFreshManagerAndRouters();

        stable0 = new MockERC20("USD Coin", "USDC", 18);
        stable1 = new MockERC20("Tether", "USDT", 18);
        stable0Currency = Currency.wrap(address(stable0));
        stable1Currency = Currency.wrap(address(stable1));

        stable0.mint(address(this), type(uint128).max);
        stable1.mint(address(this), type(uint128).max);

        stable0.approve(address(swapRouter), type(uint128).max);
        stable1.approve(address(swapRouter), type(uint128).max);
        stable0.approve(address(modifyLiquidityRouter), type(uint128).max);
        stable1.approve(address(modifyLiquidityRouter), type(uint128).max);

        oracle0 = new MockV3Aggregator(18, int256(1e18));
        oracle1 = new MockV3Aggregator(18, int256(1e18));

        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG);
        deployCodeTo("OscillonHook", abi.encode(manager), address(flags));
        hook = OscillonHook(payable(address(flags)));

        Currency c0 = stable0Currency;
        Currency c1 = stable1Currency;
        if (Currency.unwrap(c0) > Currency.unwrap(c1)) {
            (c0, c1) = (c1, c0);
        }
        console.log(Currency.unwrap(c0), Currency.unwrap(c1));

        (poolKey, ) = initPool(
            c0,
            c1,
            IHooks(address(hook)),
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            SQRT_PRICE_1_1
        );

        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            LIQUIDITY_PARAMS,
            ZERO_BYTES
        );

        // Register pool using oracle order that matches currency0/currency1.
        address oracleForCurrency0;
        address oracleForCurrency1;
        if (Currency.unwrap(poolKey.currency0) == address(stable0)) {
            oracleForCurrency0 = address(oracle0);
            oracleForCurrency1 = address(oracle1);
        } else {
            oracleForCurrency0 = address(oracle1);
            oracleForCurrency1 = address(oracle0);
        }

        // Use low-level call to avoid PoolKey type conflicts between remapped deps.
        (bool ok, ) = address(hook).call(
            abi.encodeWithSignature(
                "registerPool((address,address,uint24,int24,address),address,address,uint8,uint8)",
                Currency.unwrap(poolKey.currency0),
                Currency.unwrap(poolKey.currency1),
                poolKey.fee,
                poolKey.tickSpacing,
                address(poolKey.hooks),
                oracleForCurrency0,
                oracleForCurrency1,
                uint8(18),
                uint8(18)
            )
        );
        require(ok, "registerPool failed");
    }

    function test_swap_WhenStableDropsTo089_UsesMaxFee() public {
        // Depeg stable1 from $1.00 -> $0.89 (11% depeg = 1100 bps).
        oracle1.updateAnswer(890000000000000000);

        bool stable1IsCurrency0 = Currency.unwrap(poolKey.currency0) ==
            address(stable1);
        bool zeroForOne = stable1IsCurrency0; // sell stable1 into pool
        uint160 sqrtPriceLimitX96 = zeroForOne
            ? (TickMath.MIN_SQRT_PRICE + 1)
            : (TickMath.MAX_SQRT_PRICE - 1);

        vm.expectEmit(true, false, false, true, address(hook));
        emit DepegDetected(poolKey.toId(), 1100, MAX_FEE_PIPS, AMOUNT_IN, true);

        swapRouter.swap(
            poolKey,
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
}
