// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {HookMiner} from "v4-hooks-public/src/utils/HookMiner.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {OscillonHook} from "../src/OscillonHook.sol";
import {
    ChainlinkOracleAdapter
} from "../src/oracle/adapters/ChainlinkOracleAdapter.sol";
import {OscillonConstants as C} from "../src/constants/OscillonConstants.sol";

contract DeployOscillonHookScript is Script {
    address constant CREATE2_DEPLOYER =
        0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant ARBITRUM_POOL_MANAGER =
        0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
    address constant ARBITRUM_SEQUENCER =
        0xFdB631F5EE196F0ed6FAa767959853A9F217697D;

    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant USDT = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;
    address constant DAI = 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1;
    address constant CRVUSD = 0x498Bf2B1e120FeD3ad3D42EA2165E9b73f99C1e5;

    address constant CL_USDC_USD = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;
    address constant CL_USDT_USD = 0x3f3f5dF88dC9F13eac63DF89EC16ef6e7E25DdE7;
    address constant CL_DAI_USD = 0xc5C8E77B397E531B8EC06BFb0048328B30E9eCfB;
    address constant CL_CRVUSD_USD = 0x0a32255dd4BB6177C994bAAc73E0606fDD568f66;

    function run() external {
        address poolManager = vm.envOr("POOL_MANAGER", ARBITRUM_POOL_MANAGER);
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG |
                Hooks.AFTER_INITIALIZE_FLAG |
                Hooks.AFTER_SWAP_FLAG
        );

        bytes memory ctorArgs = abi.encode(IPoolManager(poolManager), deployer);
        (address hookAddr, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            flags,
            type(OscillonHook).creationCode,
            ctorArgs
        );

        OscillonHook hook = new OscillonHook{salt: salt}(
            IPoolManager(poolManager),
            deployer
        );
        require(address(hook) == hookAddr, "Hook address mismatch");

        ChainlinkOracleAdapter usdcAdapter = new ChainlinkOracleAdapter(
            CL_USDC_USD,
            ARBITRUM_SEQUENCER,
            C.MAX_ORACLE_AGE
        );
        ChainlinkOracleAdapter usdtAdapter = new ChainlinkOracleAdapter(
            CL_USDT_USD,
            ARBITRUM_SEQUENCER,
            C.MAX_ORACLE_AGE
        );
        ChainlinkOracleAdapter daiAdapter = new ChainlinkOracleAdapter(
            CL_DAI_USD,
            ARBITRUM_SEQUENCER,
            C.MAX_ORACLE_AGE
        );
        ChainlinkOracleAdapter crvAdapter = new ChainlinkOracleAdapter(
            CL_CRVUSD_USD,
            ARBITRUM_SEQUENCER,
            C.MAX_ORACLE_AGE
        );

        hook.approveAdapter(address(usdcAdapter));
        hook.approveAdapter(address(usdtAdapter));
        hook.approveAdapter(address(daiAdapter));
        hook.approveAdapter(address(crvAdapter));

        _registerSortedPool(
            hook,
            USDC,
            USDT,
            usdcAdapter,
            usdtAdapter,
            6,
            6,
            "USDC/USDT"
        );
        _registerSortedPool(
            hook,
            USDC,
            DAI,
            usdcAdapter,
            daiAdapter,
            6,
            18,
            "USDC/DAI"
        );
        _registerSortedPool(
            hook,
            USDT,
            DAI,
            usdtAdapter,
            daiAdapter,
            6,
            18,
            "USDT/DAI"
        );
        _registerSortedPool(
            hook,
            USDC,
            CRVUSD,
            usdcAdapter,
            crvAdapter,
            6,
            18,
            "USDC/crvUSD"
        );

        vm.stopBroadcast();

        console2.log("OscillonHook:", address(hook));
        console2.log("Owner:", deployer);
    }

    function _registerSortedPool(
        OscillonHook hook,
        address tokenA,
        address tokenB,
        ChainlinkOracleAdapter adapterA,
        ChainlinkOracleAdapter adapterB,
        uint8 decimalsA,
        uint8 decimalsB,
        string memory label
    ) internal {
        PoolKey memory key;
        if (tokenA < tokenB) {
            key = PoolKey({
                currency0: Currency.wrap(tokenA),
                currency1: Currency.wrap(tokenB),
                fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
                tickSpacing: 1,
                hooks: hook
            });
            hook.registerPool(
                key,
                address(adapterA),
                address(adapterB),
                decimalsA,
                decimalsB
            );
        } else {
            key = PoolKey({
                currency0: Currency.wrap(tokenB),
                currency1: Currency.wrap(tokenA),
                fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
                tickSpacing: 1,
                hooks: hook
            });
            hook.registerPool(
                key,
                address(adapterB),
                address(adapterA),
                decimalsB,
                decimalsA
            );
        }

        console2.log("Registered:", label);
    }
}
