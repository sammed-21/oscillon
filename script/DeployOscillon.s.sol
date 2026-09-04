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
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {HookMiner} from "v4-hooks-public/src/utils/HookMiner.sol";

import {OscillonHook} from "../src/OscillonHook.sol";
import {OscillonConstants as C} from "../src/constants/OscillonConstants.sol";
import {ChainlinkOracleAdapter} from "../src/oracle/adapters/ChainlinkOracleAdapter.sol";
import {MockV3Aggregator} from "../test/mock/MockV3Aggregator.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

contract DeployOscillon is Script {
    using PoolIdLibrary for PoolKey;

    address constant CREATE2_DEPLOYER =
        0x4e59b44847b379578588920cA78FbF26c0B4956C;

    address constant CL_USDC_USD_ARBITRUM =
        0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;
    address constant CL_USDT_USD_ARBITRUM =
        0x3f3f5dF88dC9F13eac63DF89EC16ef6e7E25DdE7;
    address constant CL_SEQUENCER_ARBITRUM =
        0xFdB631F5EE196F0ed6FAa767959853A9F217697D;

    // Arbitrum Sepolia Chainlink USD feeds
    address constant CL_USDC_USD_ARBITRUM_SEPOLIA =
        0x0153002d20B96532C639313c2d54c3dA09109309;
    address constant CL_USDT_USD_ARBITRUM_SEPOLIA =
        0x80EDee6f667eCc9f63a0a6f55578F870651f06A4;

    address constant PM_ARBITRUM = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
    // Arbitrum Sepolia v4 PoolManager (lib/v4-periphery/broadcast/01_PoolManager.s.sol/421614)
    address constant PM_ARBITRUM_SEPOLIA =
        0xFB3e0C6F74eB1a21CC1Da29aeC80D2Dfe6C9a317;

    address constant USDC_ARBITRUM = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant USDT_ARBITRUM = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;

    // Ethereum Sepolia (chainId 11155111). PoolManager address confirmed both from
    // the vendored lib/v4-periphery/broadcast/01_PoolManager.s.sol/11155111 artifact
    // AND live on-chain (owner()/protocolFeesAccrued() behave as expected, not a
    // revert) — verified 2026-09-02, do not trust without re-checking if this drifts.
    address constant PM_SEPOLIA = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    // USDe/USD — verified live via description()=="USDE / USD" and a fresh
    // updatedAt timestamp, 2026-09-02.
    address constant CL_USDE_USD_SEPOLIA =
        0x55ec7c3ed0d7CB5DF4d3d8bfEd2ecaf28b4638fb;
    // USDC/USD — verified live via description()=="USDC / USD" and a fresh
    // updatedAt timestamp, 2026-09-02.
    // RedStone-on-Chainlink-interface feeds — verified via description()/
    // decimals()/latestRoundData() on-chain, 2026-09-02. No native Chainlink
    // USDT/USD or USDC/USD feed exists on Sepolia; RedStone fills that gap.
    address constant RS_USDC_USD_SEPOLIA =
        0xAd1A270a3F7FF685B90445d9da3EE7Eb22F8A1Ec;
    address constant RS_USDT_USD_SEPOLIA =
        0xE333acACEb88B2995a06f8Af689E8e17D6C1551A;
    // RedStone's heartbeat here is ~6h, not Chainlink's ~1h — C.MAX_ORACLE_AGE
    // is tuned for Chainlink and would treat a perfectly on-schedule RedStone
    // update as stale 5 of every 6 hours. 7h gives one heartbeat of margin.
    uint256 constant RS_MAX_AGE = 7 hours;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    // Target real token depth seeded into each Sepolia multi-pool position
    // (whole tokens, scaled by each side's own decimals at use). 1000 of
    // each leaves ample headroom against the 1,000,000-token mint per token,
    // even with a token shared across two pools (USDe, USDC, USDT each
    // appear in two of the three pools).
    uint256 constant SEED_DEPTH = 1000;

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
        uint8 usdcDecimals;
        uint8 usdtDecimals;
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

        if (chainId == 11155111) {
            vm.startBroadcast(deployerKey);
            MultiPoolOutput memory mp = _deployMultiPoolSepolia(deployer);
            vm.stopBroadcast();
            _writeMultiPoolDeploymentJson(mp);
            console2.log(
                "=== Oscillon multi-pool deploy complete (Sepolia) ==="
            );
            console2.log("OscillonHook:", mp.hook);
            console2.log("USDC/USDT poolId:");
            console2.logBytes32(mp.usdcUsdtPoolId);
            console2.log("USDe/USDC poolId:");
            console2.logBytes32(mp.usdeUsdcPoolId);
            console2.log("USDe/USDT poolId:");
            console2.logBytes32(mp.usdeUsdtPoolId);
            return;
        }

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

    function _deploy(
        uint256 chainId,
        address deployer
    ) internal returns (DeployOutput memory out) {
        out.chainId = chainId;
        out.deployer = deployer;

        address pmAddr = _poolManager(chainId, deployer);
        IPoolManager poolManager = IPoolManager(pmAddr);
        out.poolManager = pmAddr;

        (out.usdc, out.usdt, out.usdcDecimals, out.usdtDecimals) = _tokens(
            chainId,
            deployer
        );
        out.oracles = _oracles(chainId);

        if (chainId == 31337 || chainId == 421614 || chainId == 11155111) {
            out.swapRouter = address(new PoolSwapTest(poolManager));
            out.liquidityRouter = address(
                new PoolModifyLiquidityTest(poolManager)
            );
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

        uint8 dec0;
        uint8 dec1;
        (out.poolKey, out.oracle0, out.oracle1, dec0, dec1) = _buildPoolKey(
            out
        );
        poolManager.initialize(out.poolKey, SQRT_PRICE_1_1);
        out.poolId = PoolId.unwrap(out.poolKey.toId());

        if (chainId == 31337 || chainId == 421614 || chainId == 11155111) {
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

        hook.registerPool(out.poolKey, out.oracle0, out.oracle1, dec0, dec1);
    }

    function _poolManager(
        uint256 chainId,
        address deployer
    ) internal returns (address) {
        if (chainId == 31337) return address(new PoolManager(deployer));
        if (chainId == 421614) return PM_ARBITRUM_SEPOLIA;
        if (chainId == 42161) return PM_ARBITRUM;
        if (chainId == 11155111) return PM_SEPOLIA;
        revert("DeployOscillon: unsupported chainId");
    }

    function _tokens(
        uint256 chainId,
        address deployer
    )
        internal
        returns (
            address usdc,
            address usdt,
            uint8 usdcDecimals,
            uint8 usdtDecimals
        )
    {
        if (chainId == 31337 || chainId == 421614) {
            MockERC20 mockUsdc = new MockERC20("USD Coin", "USDC", 6);
            MockERC20 mockUsdt = new MockERC20("Tether USD", "USDT", 6);
            mockUsdc.mint(deployer, 1_000_000 * 1e6);
            mockUsdt.mint(deployer, 1_000_000 * 1e6);
            return (address(mockUsdc), address(mockUsdt), 6, 6);
        }
        if (chainId == 42161) return (USDC_ARBITRUM, USDT_ARBITRUM, 6, 6);
        revert("DeployOscillon: unsupported chainId");
    }

    function _oracles(
        uint256 chainId
    ) internal returns (OracleBundle memory o) {
        if (chainId == 31337) {
            MockV3Aggregator feed0 = new MockV3Aggregator(8, int256(1e8));
            MockV3Aggregator feed1 = new MockV3Aggregator(8, int256(1e8));
            o.usdcFeed = address(feed0);
            o.usdtFeed = address(feed1);
            o.usdcAdapter = address(
                new ChainlinkOracleAdapter(
                    o.usdcFeed,
                    address(0),
                    C.MAX_ORACLE_AGE
                )
            );
            o.usdtAdapter = address(
                new ChainlinkOracleAdapter(
                    o.usdtFeed,
                    address(0),
                    C.MAX_ORACLE_AGE
                )
            );
            return o;
        }
        if (chainId == 421614) {
            o.usdcFeed = CL_USDC_USD_ARBITRUM_SEPOLIA;
            o.usdtFeed = CL_USDT_USD_ARBITRUM_SEPOLIA;
            o.usdcAdapter = address(
                new ChainlinkOracleAdapter(
                    o.usdcFeed,
                    address(0),
                    C.MAX_ORACLE_AGE
                )
            );
            o.usdtAdapter = address(
                new ChainlinkOracleAdapter(
                    o.usdtFeed,
                    address(0),
                    C.MAX_ORACLE_AGE
                )
            );
            return o;
        }
        if (chainId == 42161) {
            o.usdcFeed = CL_USDC_USD_ARBITRUM;
            o.usdtFeed = CL_USDT_USD_ARBITRUM;
            o.usdcAdapter = address(
                new ChainlinkOracleAdapter(
                    o.usdcFeed,
                    CL_SEQUENCER_ARBITRUM,
                    C.MAX_ORACLE_AGE
                )
            );
            o.usdtAdapter = address(
                new ChainlinkOracleAdapter(
                    o.usdtFeed,
                    CL_SEQUENCER_ARBITRUM,
                    C.MAX_ORACLE_AGE
                )
            );
            return o;
        }
        revert("DeployOscillon: unsupported chainId");
    }

    function _deployHook(
        IPoolManager poolManager,
        address initialOwner
    ) internal returns (address hook) {
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG |
                Hooks.AFTER_INITIALIZE_FLAG |
                Hooks.AFTER_SWAP_FLAG
        );
        bytes memory ctorArgs = abi.encode(poolManager, initialOwner);
        (address hookAddr, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            flags,
            type(OscillonHook).creationCode,
            ctorArgs
        );
        OscillonHook deployed = new OscillonHook{salt: salt}(
            poolManager,
            initialOwner
        );
        require(
            address(deployed) == hookAddr,
            "DeployOscillon: hook address mismatch"
        );
        return address(deployed);
    }

    function _buildPoolKey(
        DeployOutput memory out
    )
        internal
        pure
        returns (
            PoolKey memory key,
            address oracle0,
            address oracle1,
            uint8 decimals0,
            uint8 decimals1
        )
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
            decimals0 = out.usdcDecimals;
            decimals1 = out.usdtDecimals;
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
            decimals0 = out.usdtDecimals;
            decimals1 = out.usdcDecimals;
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
        vm.serializeAddress(
            root,
            "poolCurrency0",
            Currency.unwrap(out.poolKey.currency0)
        );
        vm.serializeAddress(
            root,
            "poolCurrency1",
            Currency.unwrap(out.poolKey.currency1)
        );
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

    // ── Sepolia: 3 pools (USDC/USDT, USDe/USDC, USDe/USDT) sharing 3 tokens ──

    struct TokenSpec {
        address token;
        address adapter;
        uint8 decimals;
    }

    struct MultiPoolOutput {
        address deployer;
        address poolManager;
        address swapRouter;
        address liquidityRouter;
        address hook;
        address usde;
        address usdc;
        address usdt;
        address usdeAdapter;
        address usdcAdapter;
        address usdtAdapter;
        PoolKey usdcUsdtKey;
        bytes32 usdcUsdtPoolId;
        PoolKey usdeUsdcKey;
        bytes32 usdeUsdcPoolId;
        PoolKey usdeUsdtKey;
        bytes32 usdeUsdtPoolId;
    }

    function _deployMultiPoolSepolia(
        address deployer
    ) internal returns (MultiPoolOutput memory out) {
        out.deployer = deployer;
        out.poolManager = PM_SEPOLIA;
        IPoolManager poolManager = IPoolManager(PM_SEPOLIA);

        out.swapRouter = address(new PoolSwapTest(poolManager));
        out.liquidityRouter = address(new PoolModifyLiquidityTest(poolManager));

        MockERC20 usde = new MockERC20("Ethena USDe", "USDe", 18);
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 usdt = new MockERC20("Tether USD", "USDT", 6);
        usde.mint(deployer, 1_000_000 * 1e18);
        usdc.mint(deployer, 1_000_000 * 1e6);
        usdt.mint(deployer, 1_000_000 * 1e6);
        usde.approve(out.swapRouter, type(uint256).max);
        usdc.approve(out.swapRouter, type(uint256).max);
        usdt.approve(out.swapRouter, type(uint256).max);
        usde.approve(out.liquidityRouter, type(uint256).max);
        usdc.approve(out.liquidityRouter, type(uint256).max);
        usdt.approve(out.liquidityRouter, type(uint256).max);

        // USDe priced by Chainlink; USDC/USDT priced by RedStone (no native
        // Chainlink feed for either on Sepolia) — both expose a
        // latestRoundData()-compatible interface, so the same adapter works.
        out.usdeAdapter = address(
            new ChainlinkOracleAdapter(
                CL_USDE_USD_SEPOLIA,
                address(0),
                C.MAX_ORACLE_AGE
            )
        );
        out.usdcAdapter = address(
            new ChainlinkOracleAdapter(
                RS_USDC_USD_SEPOLIA,
                address(0),
                RS_MAX_AGE
            )
        );
        out.usdtAdapter = address(
            new ChainlinkOracleAdapter(
                RS_USDT_USD_SEPOLIA,
                address(0),
                RS_MAX_AGE
            )
        );

        out.hook = _deployHook(poolManager, deployer);
        OscillonHook hook = OscillonHook(payable(out.hook));
        hook.approveAdapter(out.usdeAdapter);
        hook.approveAdapter(out.usdcAdapter);
        hook.approveAdapter(out.usdtAdapter);

        TokenSpec memory usdeSpec = TokenSpec(
            address(usde),
            out.usdeAdapter,
            18
        );
        TokenSpec memory usdcSpec = TokenSpec(
            address(usdc),
            out.usdcAdapter,
            6
        );
        TokenSpec memory usdtSpec = TokenSpec(
            address(usdt),
            out.usdtAdapter,
            6
        );

        (out.usdcUsdtKey, out.usdcUsdtPoolId) = _buildAndRegisterPool(
            hook,
            poolManager,
            out.hook,
            out.liquidityRouter,
            usdcSpec,
            usdtSpec
        );
        (out.usdeUsdcKey, out.usdeUsdcPoolId) = _buildAndRegisterPool(
            hook,
            poolManager,
            out.hook,
            out.liquidityRouter,
            usdeSpec,
            usdcSpec
        );
        (out.usdeUsdtKey, out.usdeUsdtPoolId) = _buildAndRegisterPool(
            hook,
            poolManager,
            out.hook,
            out.liquidityRouter,
            usdeSpec,
            usdtSpec
        );

        out.usde = address(usde);
        out.usdc = address(usdc);
        out.usdt = address(usdt);
    }

    function _buildAndRegisterPool(
        OscillonHook hook,
        IPoolManager poolManager,
        address hookAddr,
        address liquidityRouter,
        TokenSpec memory a,
        TokenSpec memory b
    ) internal returns (PoolKey memory key, bytes32 poolId) {
        (
            address c0,
            address c1,
            address oracle0,
            address oracle1,
            uint8 dec0,
            uint8 dec1
        ) = a.token < b.token
                ? (
                    a.token,
                    b.token,
                    a.adapter,
                    b.adapter,
                    a.decimals,
                    b.decimals
                )
                : (
                    b.token,
                    a.token,
                    b.adapter,
                    a.adapter,
                    b.decimals,
                    a.decimals
                );

        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: int24(1),
            hooks: IHooks(hookAddr)
        });

        uint160 sqrtPriceX96 = _initialSqrtPriceX96(dec0, dec1);
        poolManager.initialize(key, sqrtPriceX96);
        poolId = PoolId.unwrap(key.toId());

        // Center the liquidity range on the ACTUAL initial tick, not 0 — for
        // equal-decimal pairs that's the same range as before, but for a
        // real decimal gap (e.g. USDe/USDC) the true price sits far from
        // tick 0 and a fixed [-120,120] range would be entirely inactive.
        int24 centerTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

        PoolModifyLiquidityTest(liquidityRouter).modifyLiquidity(
            key,
            _seedLiquidityParams(sqrtPriceX96, centerTick, dec0, dec1),
            ""
        );

        hook.registerPool(key, oracle0, oracle1, dec0, dec1);
    }

    /// @dev Split out of _buildAndRegisterPool purely to keep that function's
    ///      stack depth under the legacy codegen limit.
    ///
    ///      A flat liquidityDelta constant is meaningless across pools at
    ///      very different absolute price levels — the same raw liquidity
    ///      units that give a ~1:1-priced pool (USDC/USDT) thousands of
    ///      tokens of real depth give a ~1e-12-priced pool (USDe/USDC or
    ///      USDe/USDT, 18 vs 6 decimals) a small FRACTION of a token of real
    ///      depth, because liquidity math ties token amounts to the absolute
    ///      price, not just the relative tick width. Size liquidity from an
    ///      actual target token depth instead, computed per-pool from its
    ///      own price.
    function _seedLiquidityParams(
        uint160 sqrtPriceX96,
        int24 centerTick,
        uint8 dec0,
        uint8 dec1
    ) private pure returns (ModifyLiquidityParams memory) {
        int24 tickLower = centerTick - 120;
        int24 tickUpper = centerTick + 120;

        uint128 liquidityAmount = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            SEED_DEPTH * (10 ** uint256(dec0)),
            SEED_DEPTH * (10 ** uint256(dec1))
        );

        return ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: int256(uint256(liquidityAmount)),
            salt: bytes32(0)
        });
    }

    /// @dev v4 prices in raw smallest-unit ratios, not dollar-normalized
    ///      amounts — SQRT_PRICE_1_1 ("1 raw unit0 = 1 raw unit1") is only a
    ///      fair $1:$1 price when dec0 == dec1. For a real decimal gap (e.g.
    ///      USDe 18 vs USDC 6), the correct dollar-parity price is
    ///      10^(dec1-dec0), and sqrtPriceX96 scales by 10^(|diff|/2) off of
    ///      SQRT_PRICE_1_1 (== exactly 2^96) accordingly. Every USD-stable
    ///      decimal pairing actually used here (6/8/18) has an even diff, so
    ///      this needs no general integer-sqrt routine — an odd diff would.
    function _initialSqrtPriceX96(
        uint8 dec0,
        uint8 dec1
    ) internal pure returns (uint160) {
        if (dec0 == dec1) return SQRT_PRICE_1_1;
        if (dec1 > dec0) {
            uint256 diff = uint256(dec1) - uint256(dec0);
            require(
                diff % 2 == 0,
                "DeployOscillon: unsupported odd decimal diff"
            );
            return uint160(uint256(SQRT_PRICE_1_1) * (10 ** (diff / 2)));
        }
        uint256 diffDown = uint256(dec0) - uint256(dec1);
        require(
            diffDown % 2 == 0,
            "DeployOscillon: unsupported odd decimal diff"
        );
        return uint160(uint256(SQRT_PRICE_1_1) / (10 ** (diffDown / 2)));
    }

    function _writeMultiPoolDeploymentJson(
        MultiPoolOutput memory out
    ) internal {
        string memory root = "mpDeployment";
        vm.serializeUint(root, "chainId", uint256(11155111));
        vm.serializeString(root, "chainName", "ethereum-sepolia");
        vm.serializeString(root, "deployedAt", vm.toString(block.timestamp));
        vm.serializeAddress(root, "deployer", out.deployer);
        vm.serializeAddress(root, "poolManager", out.poolManager);
        vm.serializeAddress(root, "swapRouter", out.swapRouter);
        vm.serializeAddress(root, "liquidityRouter", out.liquidityRouter);
        vm.serializeAddress(root, "oscillonHook", out.hook);
        vm.serializeAddress(root, "usde", out.usde);
        vm.serializeAddress(root, "usdc", out.usdc);
        vm.serializeAddress(root, "usdt", out.usdt);
        vm.serializeAddress(root, "usdeAdapter", out.usdeAdapter);
        vm.serializeAddress(root, "usdcAdapter", out.usdcAdapter);
        vm.serializeAddress(root, "usdtAdapter", out.usdtAdapter);
        vm.serializeAddress(root, "usdeFeed", CL_USDE_USD_SEPOLIA);
        vm.serializeAddress(root, "usdcFeed", RS_USDC_USD_SEPOLIA);
        vm.serializeAddress(root, "usdtFeed", RS_USDT_USD_SEPOLIA);

        vm.serializeAddress(
            root,
            "usdcUsdt_currency0",
            Currency.unwrap(out.usdcUsdtKey.currency0)
        );
        vm.serializeAddress(
            root,
            "usdcUsdt_currency1",
            Currency.unwrap(out.usdcUsdtKey.currency1)
        );
        vm.serializeBytes32(root, "usdcUsdt_poolId", out.usdcUsdtPoolId);

        vm.serializeAddress(
            root,
            "usdeUsdc_currency0",
            Currency.unwrap(out.usdeUsdcKey.currency0)
        );
        vm.serializeAddress(
            root,
            "usdeUsdc_currency1",
            Currency.unwrap(out.usdeUsdcKey.currency1)
        );
        vm.serializeBytes32(root, "usdeUsdc_poolId", out.usdeUsdcPoolId);

        vm.serializeAddress(
            root,
            "usdeUsdt_currency0",
            Currency.unwrap(out.usdeUsdtKey.currency0)
        );
        vm.serializeAddress(
            root,
            "usdeUsdt_currency1",
            Currency.unwrap(out.usdeUsdtKey.currency1)
        );
        string memory json = vm.serializeBytes32(
            root,
            "usdeUsdt_poolId",
            out.usdeUsdtPoolId
        );

        string memory projectRoot = vm.projectRoot();
        string memory rootPath = string.concat(projectRoot, "/deployment.json");
        string memory uiPath = vm.envOr(
            "FRONTEND_DEPLOYMENT_JSON",
            string.concat(projectRoot, "/oscillon-ui/src/deployment.json")
        );

        string memory chainKey = ".11155111";
        vm.writeJson(json, rootPath, chainKey);
        vm.writeJson(json, uiPath, chainKey);

        console2.log("deployment.json ->", rootPath);
        console2.log("deployment.json ->", uiPath);
    }
}
