// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title DeployOscillon
 * @notice Deploys OscillonHook + dependencies and writes deployment.json (root + oscillon-ui/src).
 *
 *   Set PRIVATE_KEY in .env (must include 0x prefix), then:
 *
 *   forge script script/DeployOscillon.s.sol:DeployOscillon \
 *     --rpc-url $RPC_URL \
 *     --broadcast
 */

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {HookMiner} from "v4-hooks-public/src/utils/HookMiner.sol";

import {OscillonHook} from "../src/OscillonHook.sol";
import {ChainlinkOracleAdapter} from "../src/oracle/adapters/ChainlinkOracleAdapter.sol";
import {MockV3Aggregator} from "../test/mock/MockV3Aggregator.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

contract DeployOscillon is Script {
    using PoolIdLibrary for PoolKey;

    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    address constant CL_USDC_USD_ARBITRUM = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;
    address constant CL_USDT_USD_ARBITRUM = 0x3f3f5dF88dC9F13eac63DF89EC16ef6e7E25DdE7;
    address constant CL_SEQUENCER_ARBITRUM = 0xFdB631F5EE196F0ed6FAa767959853A9F217697D;

    // Arbitrum Sepolia Chainlink USD feeds
    address constant CL_USDC_USD_ARBITRUM_SEPOLIA = 0x0153002d20B96532C639313c2d54c3dA09109309;
    address constant CL_USDT_USD_ARBITRUM_SEPOLIA = 0x80EDee6f667eCc9f63a0a6f55578F870651f06A4;

    address constant PM_ARBITRUM = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
    // Arbitrum Sepolia v4 PoolManager (lib/v4-periphery/broadcast/01_PoolManager.s.sol/421614)
    address constant PM_ARBITRUM_SEPOLIA = 0xFB3e0C6F74eB1a21CC1Da29aeC80D2Dfe6C9a317;

    address constant USDC_ARBITRUM = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant USDT_ARBITRUM = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;

    uint256 constant MAX_ORACLE_AGE = 25 hours;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    struct OracleBundle {
        address usdcAdapter;
        address usdtAdapter;
        address usdcFeed;
        address usdtFeed;
    }

    struct DeployOutput {
        uint256 chainId;
        address deployer;
        address poolManager;
        address swapRouter;
        address liquidityRouter;
        address hook;
        address usdc;
        address usdt;
        OracleBundle oracles;
        address oracle0;
        address oracle1;
        PoolKey poolKey;
        bytes32 poolId;
    }

    function run() external {
        uint256 chainId = block.chainid;
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);
        DeployOutput memory out = _deploy(chainId, deployer);
        vm.stopBroadcast();

        _writeDeploymentJson(out);

        console2.log("=== Oscillon deploy complete ===");
        console2.log("Chain:", out.chainId);
        console2.log("PoolManager:", out.poolManager);
        console2.log("SwapRouter:", out.swapRouter);
        console2.log("LiquidityRouter:", out.liquidityRouter);
        console2.log("OscillonHook:", out.hook);
        console2.log("PoolId:");
        console2.logBytes32(out.poolId);
    }

    function _deploy(uint256 chainId, address deployer) internal returns (DeployOutput memory out) {
        out.chainId = chainId;
        out.deployer = deployer;

        address pmAddr = _poolManager(chainId, deployer);
        IPoolManager poolManager = IPoolManager(pmAddr);
        out.poolManager = pmAddr;

        (out.usdc, out.usdt) = _tokens(chainId, deployer);
        out.oracles = _oracles(chainId);

        if (chainId == 31337 || chainId == 421614) {
            out.swapRouter = address(new PoolSwapTest(poolManager));
            out.liquidityRouter = address(new PoolModifyLiquidityTest(poolManager));
            // Only on Anvil — deployer owns the freshly deployed PoolManager.
            if (chainId == 31337) {
                PoolManager(pmAddr).setProtocolFeeController(deployer);
            }
            _approveRouters(out);
        }

        out.hook = _deployHook(poolManager, deployer);
        OscillonHook hook = OscillonHook(payable(out.hook));
        hook.approveAdapter(out.oracles.usdcAdapter);
        hook.approveAdapter(out.oracles.usdtAdapter);

        (out.poolKey, out.oracle0, out.oracle1) = _buildPoolKey(out);
        poolManager.initialize(out.poolKey, SQRT_PRICE_1_1);
        out.poolId = PoolId.unwrap(out.poolKey.toId());

        if (chainId == 31337 || chainId == 421614) {
            PoolModifyLiquidityTest(out.liquidityRouter).modifyLiquidity(
                out.poolKey,
                ModifyLiquidityParams({
                    tickLower: -120,
                    tickUpper: 120,
                    liquidityDelta: 1e12,
                    salt: bytes32(0)
                }),
                ""
            );
        }

        hook.registerPool(
            out.poolKey,
            out.oracle0,
            out.oracle1,
            uint8(6),
            uint8(6)
        );
    }

    function _poolManager(uint256 chainId, address deployer) internal returns (address) {
        if (chainId == 31337) return address(new PoolManager(deployer));
        if (chainId == 421614) return PM_ARBITRUM_SEPOLIA;
        if (chainId == 42161) return PM_ARBITRUM;
        revert("DeployOscillon: unsupported chainId");
    }

    function _tokens(uint256 chainId, address deployer) internal returns (address usdc, address usdt) {
        if (chainId == 31337 || chainId == 421614) {
            MockERC20 mockUsdc = new MockERC20("USD Coin", "USDC", 6);
            MockERC20 mockUsdt = new MockERC20("Tether USD", "USDT", 6);
            mockUsdc.mint(deployer, 1_000_000 * 1e6);
            mockUsdt.mint(deployer, 1_000_000 * 1e6);
            return (address(mockUsdc), address(mockUsdt));
        }
        if (chainId == 42161) return (USDC_ARBITRUM, USDT_ARBITRUM);
        revert("DeployOscillon: unsupported chainId");
    }

    function _oracles(uint256 chainId) internal returns (OracleBundle memory o) {
        if (chainId == 31337) {
            MockV3Aggregator feed0 = new MockV3Aggregator(8, int256(1e8));
            MockV3Aggregator feed1 = new MockV3Aggregator(8, int256(1e8));
            o.usdcFeed = address(feed0);
            o.usdtFeed = address(feed1);
            o.usdcAdapter = address(
                new ChainlinkOracleAdapter(o.usdcFeed, address(0), MAX_ORACLE_AGE)
            );
            o.usdtAdapter = address(
                new ChainlinkOracleAdapter(o.usdtFeed, address(0), MAX_ORACLE_AGE)
            );
            return o;
        }
        if (chainId == 421614) {
            o.usdcFeed = CL_USDC_USD_ARBITRUM_SEPOLIA;
            o.usdtFeed = CL_USDT_USD_ARBITRUM_SEPOLIA;
            o.usdcAdapter = address(
                new ChainlinkOracleAdapter(o.usdcFeed, address(0), MAX_ORACLE_AGE)
            );
            o.usdtAdapter = address(
                new ChainlinkOracleAdapter(o.usdtFeed, address(0), MAX_ORACLE_AGE)
            );
            return o;
        }
        if (chainId == 42161) {
            o.usdcFeed = CL_USDC_USD_ARBITRUM;
            o.usdtFeed = CL_USDT_USD_ARBITRUM;
            o.usdcAdapter = address(
                new ChainlinkOracleAdapter(o.usdcFeed, CL_SEQUENCER_ARBITRUM, MAX_ORACLE_AGE)
            );
            o.usdtAdapter = address(
                new ChainlinkOracleAdapter(o.usdtFeed, CL_SEQUENCER_ARBITRUM, MAX_ORACLE_AGE)
            );
            return o;
        }
        revert("DeployOscillon: unsupported chainId");
    }

    function _deployHook(IPoolManager poolManager, address initialOwner) internal returns (address hook) {
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        bytes memory ctorArgs = abi.encode(poolManager, initialOwner);
        (address hookAddr, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            flags,
            type(OscillonHook).creationCode,
            ctorArgs
        );
        OscillonHook deployed = new OscillonHook{salt: salt}(poolManager, initialOwner);
        require(address(deployed) == hookAddr, "DeployOscillon: hook address mismatch");
        return address(deployed);
    }

    function _buildPoolKey(DeployOutput memory out)
        internal
        pure
        returns (PoolKey memory key, address oracle0, address oracle1)
    {
        if (out.usdc < out.usdt) {
            key = PoolKey({
                currency0: Currency.wrap(out.usdc),
                currency1: Currency.wrap(out.usdt),
                fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
                tickSpacing: int24(1),
                hooks: IHooks(out.hook)
            });
            oracle0 = out.oracles.usdcAdapter;
            oracle1 = out.oracles.usdtAdapter;
        } else {
            key = PoolKey({
                currency0: Currency.wrap(out.usdt),
                currency1: Currency.wrap(out.usdc),
                fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
                tickSpacing: int24(1),
                hooks: IHooks(out.hook)
            });
            oracle0 = out.oracles.usdtAdapter;
            oracle1 = out.oracles.usdcAdapter;
        }
    }

    function _approveRouters(DeployOutput memory out) internal {
        MockERC20(out.usdc).approve(out.swapRouter, type(uint256).max);
        MockERC20(out.usdt).approve(out.swapRouter, type(uint256).max);
        MockERC20(out.usdc).approve(out.liquidityRouter, type(uint256).max);
        MockERC20(out.usdt).approve(out.liquidityRouter, type(uint256).max);
    }

    function _writeDeploymentJson(DeployOutput memory out) internal {
        string memory root = "deployment";
        vm.serializeUint(root, "chainId", out.chainId);
        vm.serializeString(root, "chainName", _chainName(out.chainId));
        vm.serializeString(root, "deployedAt", vm.toString(block.timestamp));
        vm.serializeAddress(root, "deployer", out.deployer);
        vm.serializeAddress(root, "poolManager", out.poolManager);
        vm.serializeAddress(root, "swapRouter", out.swapRouter);
        vm.serializeAddress(root, "liquidityRouter", out.liquidityRouter);
        vm.serializeAddress(root, "oscillonHook", out.hook);
        vm.serializeAddress(root, "usdc", out.usdc);
        vm.serializeAddress(root, "usdt", out.usdt);
        vm.serializeAddress(root, "chainlinkFeed0", out.oracles.usdcFeed);
        vm.serializeAddress(root, "chainlinkFeed1", out.oracles.usdtFeed);
        vm.serializeAddress(root, "chainlinkAdapter0", out.oracles.usdcAdapter);
        vm.serializeAddress(root, "chainlinkAdapter1", out.oracles.usdtAdapter);
        vm.serializeAddress(root, "oracle0", out.oracle0);
        vm.serializeAddress(root, "oracle1", out.oracle1);
        vm.serializeAddress(root, "poolCurrency0", Currency.unwrap(out.poolKey.currency0));
        vm.serializeAddress(root, "poolCurrency1", Currency.unwrap(out.poolKey.currency1));
        vm.serializeUint(root, "poolFee", out.poolKey.fee);
        vm.serializeInt(root, "poolTickSpacing", out.poolKey.tickSpacing);
        vm.serializeAddress(root, "poolHooks", address(out.poolKey.hooks));
        string memory json = vm.serializeBytes32(root, "poolId", out.poolId);

        string memory projectRoot = vm.projectRoot();
        string memory rootPath = string.concat(projectRoot, "/deployment.json");
        string memory uiPath = vm.envOr(
            "FRONTEND_DEPLOYMENT_JSON",
            string.concat(projectRoot, "/oscillon-ui/src/deployment.json")
        );

        // Merge into chain-keyed registry: { "31337": { ... }, "421614": { ... } }
        string memory chainKey = string.concat(".", vm.toString(out.chainId));
        vm.writeJson(json, rootPath, chainKey);
        vm.writeJson(json, uiPath, chainKey);

        console2.log("deployment.json ->", rootPath);
        console2.log("deployment.json key ->", chainKey);
        console2.log("deployment.json ->", uiPath);
    }

    function _chainName(uint256 chainId) internal pure returns (string memory) {
        if (chainId == 31337) return "anvil";
        if (chainId == 421614) return "arbitrum-sepolia";
        if (chainId == 42161) return "arbitrum";
        if (chainId == 11155111) return "ethereum-sepolia";
        return "unknown";
    }
}
