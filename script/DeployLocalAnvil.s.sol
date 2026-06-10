// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {
    PoolModifyLiquidityTest
} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {
    ModifyLiquidityParams
} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {HookMiner} from "v4-hooks-public/src/utils/HookMiner.sol";

import {OscillonHook} from "../src/OscillonHook.sol";
import {
    ChainlinkOracleAdapter
} from "../src/oracle/adapters/ChainlinkOracleAdapter.sol";
import {MockV3Aggregator} from "../test/mock/MockV3Aggregator.sol";

/// @notice Full local stack: tokens, oracles, hook, pool, liquidity.
contract DeployLocalAnvilScript is Script {
    address constant CREATE2_DEPLOYER =
        0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    struct Deployed {
        PoolManager manager;
        PoolSwapTest swapRouter;
        PoolModifyLiquidityTest liqRouter;
        MockERC20 usdc;
        MockERC20 usdt;
        MockV3Aggregator clUsdc;
        MockV3Aggregator clUsdt;
        OscillonHook hook;
    }

    function run() external {
        uint256 deployerKey = vm.envOr(
            "PRIVATE_KEY",
            uint256(
                0xac0974bec39a17e36ba4a6b4d0ff2cffc6c2bffe6a6861c259c265d822f864
            )
        );
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);
        Deployed memory d = _deployAll(deployer);
        vm.stopBroadcast();

        console2.log("=== LOCAL DEPLOY ===");
        console2.log("Deployer:", deployer);
        console2.log("PoolManager:", address(d.manager));
        console2.log("SwapRouter:", address(d.swapRouter));
        console2.log("LiqRouter:", address(d.liqRouter));
        console2.log("USDC:", address(d.usdc));
        console2.log("USDT:", address(d.usdt));
        console2.log("CL USDC:", address(d.clUsdc));
        console2.log("CL USDT:", address(d.clUsdt));
        console2.log("OscillonHook:", address(d.hook));
    }

    function _deployAll(address deployer) internal returns (Deployed memory d) {
        d.manager = new PoolManager(deployer);
        d.swapRouter = new PoolSwapTest(d.manager);
        d.liqRouter = new PoolModifyLiquidityTest(d.manager);
        d.manager.setProtocolFeeController(deployer);

        d.usdc = new MockERC20("USD Coin", "USDC", 18);
        d.usdt = new MockERC20("Tether", "USDT", 18);
        d.usdc.mint(deployer, type(uint128).max);
        d.usdt.mint(deployer, type(uint128).max);

        d.usdc.approve(address(d.swapRouter), type(uint256).max);
        d.usdt.approve(address(d.swapRouter), type(uint256).max);
        d.usdc.approve(address(d.liqRouter), type(uint256).max);
        d.usdt.approve(address(d.liqRouter), type(uint256).max);

        d.clUsdc = new MockV3Aggregator(18, int256(1e18));
        d.clUsdt = new MockV3Aggregator(18, int256(1e18));

        ChainlinkOracleAdapter usdcAdapter = new ChainlinkOracleAdapter(
            address(d.clUsdc),
            address(0),
            25 hours
        );
        ChainlinkOracleAdapter usdtAdapter = new ChainlinkOracleAdapter(
            address(d.clUsdt),
            address(0),
            25 hours
        );

        d.hook = _deployHook(d.manager, deployer);
        d.hook.approveAdapter(address(usdcAdapter));
        d.hook.approveAdapter(address(usdtAdapter));

        _initPoolAndRegister(d, usdcAdapter, usdtAdapter);
    }

    function _deployHook(
        PoolManager manager,
        address initialOwner
    ) internal returns (OscillonHook hook) {
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG |
                Hooks.AFTER_INITIALIZE_FLAG |
                Hooks.AFTER_SWAP_FLAG
        );
        bytes memory ctorArgs = abi.encode(
            IPoolManager(address(manager)),
            initialOwner
        );
        (address hookAddr, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            flags,
            type(OscillonHook).creationCode,
            ctorArgs
        );
        hook = new OscillonHook{salt: salt}(
            IPoolManager(address(manager)),
            initialOwner
        );
        require(address(hook) == hookAddr, "hook address mismatch");
    }

    function _initPoolAndRegister(
        Deployed memory d,
        ChainlinkOracleAdapter usdcAdapter,
        ChainlinkOracleAdapter usdtAdapter
    ) internal {
        (
            Currency c0,
            Currency c1,
            address adapter0,
            address adapter1
        ) = _sortedPair(d.usdc, d.usdt, usdcAdapter, usdtAdapter);

        PoolKey memory key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 1,
            hooks: IHooks(address(d.hook))
        });

        d.manager.initialize(key, SQRT_PRICE_1_1);
        d.liqRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: 1e18,
                salt: bytes32(0)
            }),
            ""
        );
        d.hook.registerPool(key, adapter0, adapter1, 18, 18);
    }

    function _sortedPair(
        MockERC20 usdc,
        MockERC20 usdt,
        ChainlinkOracleAdapter usdcAdapter,
        ChainlinkOracleAdapter usdtAdapter
    )
        internal
        pure
        returns (Currency c0, Currency c1, address adapter0, address adapter1)
    {
        if (address(usdc) < address(usdt)) {
            return (
                Currency.wrap(address(usdc)),
                Currency.wrap(address(usdt)),
                address(usdcAdapter),
                address(usdtAdapter)
            );
        }
        return (
            Currency.wrap(address(usdt)),
            Currency.wrap(address(usdc)),
            address(usdtAdapter),
            address(usdcAdapter)
        );
    }
}
