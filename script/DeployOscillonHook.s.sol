// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/*
 * DeployOscillonHook.s.sol
 *
 * Deploys OscillonHook and registers 4 stable pools.
 *
 * Run:
 *   forge script script/DeployOscillonHook.s.sol:DeployOscillonHookScript \
 *     --rpc-url $ARBITRUM_RPC \
 *     --broadcast --verify
 */

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {HookMiner} from "v4-hooks-public/src/utils/HookMiner.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {OscillonHook} from "../src/OscillonHook.sol";

contract DeployOscillonHookScript is Script {
    // Foundry deterministic CREATE2 deployer proxy
    address constant CREATE2_DEPLOYER =
        0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // Arbitrum v4 PoolManager from Uniswap v4 deployments
    address constant ARBITRUM_POOL_MANAGER =
        0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;

    // Stablecoins
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant USDT = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;
    address constant DAI = 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1;
    address constant CRVUSD = 0x498Bf2B1e120FeD3ad3D42EA2165E9b73f99C1e5;

    // Chainlink USD feeds on Arbitrum
    address constant CL_USDC_USD = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;
    address constant CL_USDT_USD = 0x3f3f5dF88dC9F13eac63DF89EC16ef6e7E25DdE7;
    address constant CL_DAI_USD = 0xc5C8E77B397E531B8EC06BFb0048328B30E9eCfB;
    address constant CL_CRVUSD_USD = 0x0a32255dd4BB6177C994bAAc73E0606fDD568f66;

    function run() external {
        address poolManager = vm.envOr(
            "POOL_MANAGER",
            ARBITRUM_POOL_MANAGER
        );
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG);

        (address hookAddr, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            flags,
            type(OscillonHook).creationCode,
            abi.encode(IPoolManager(poolManager))
        );

        OscillonHook hook = new OscillonHook{salt: salt}(
            IPoolManager(poolManager)
        );

        require(address(hook) == hookAddr, "Hook address mismatch");
        console2.log("OscillonHook deployed at:", address(hook));
        console2.log("PoolManager:", poolManager);

        _registerSortedPool(
            hook,
            USDC,
            USDT,
            CL_USDC_USD,
            CL_USDT_USD,
            6,
            6,
            "USDC/USDT"
        );
        _registerSortedPool(
            hook,
            USDC,
            DAI,
            CL_USDC_USD,
            CL_DAI_USD,
            6,
            18,
            "USDC/DAI"
        );
        _registerSortedPool(
            hook,
            USDT,
            DAI,
            CL_USDT_USD,
            CL_DAI_USD,
            6,
            18,
            "USDT/DAI"
        );
        _registerSortedPool(
            hook,
            USDC,
            CRVUSD,
            CL_USDC_USD,
            CL_CRVUSD_USD,
            6,
            18,
            "USDC/crvUSD"
        );

        vm.stopBroadcast();

        console2.log("=== OSCILLON DEPLOYMENT COMPLETE ===");
        console2.log("Hook address :", address(hook));
        console2.log("Owner        :", deployer);
        console2.log("Pools active : 4");
        console2.log("Next step    : seed each pool with liquidity");
        console2.log("Then         : verify on Arbiscan and submit to 1inch");
    }

    function _registerSortedPool(
        OscillonHook hook,
        address tokenA,
        address tokenB,
        address oracleA,
        address oracleB,
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
            hook.registerPool(key, oracleA, oracleB, decimalsA, decimalsB);
        } else {
            key = PoolKey({
                currency0: Currency.wrap(tokenB),
                currency1: Currency.wrap(tokenA),
                fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
                tickSpacing: 1,
                hooks: hook
            });
            hook.registerPool(key, oracleB, oracleA, decimalsB, decimalsA);
        }

        console2.log("Registered:", label);
    }
}
