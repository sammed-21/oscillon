// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-hooks-public/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OscillonConstants as C} from "./constants/OscillonConstants.sol";
import {
    PoolConfig,
    TokenOracleConfig,
    SwapContext,
    Observation,
    TwapState,
    PriceResult
} from "./types/OscillonTypes.sol";
import {
    NotOwner,
    PoolNotRegistered,
    PoolAlreadyRegistered,
    UnsupportedToken,
    ZeroAddress,
    SameStable,
    NotStablePool,
    AdapterNotApproved,
    ExactOutputDisabledDuringDepeg,
    SwapCapExceeded,
    TransferFailed
} from "./errors/OscillonErrors.sol";
import {OscillonFeePolicy} from "./libraries/OscillonFeePolicy.sol";
import {OscillonTwapOracle} from "./libraries/OscillonTwapOracle.sol";
import {OscillonPriceEngine} from "./oracle/OscillonPriceEngine.sol";
import {IOscillonOracle} from "./oracle/IOscillonOracle.sol";

/// @title OscillonHook
/// @notice Inventory-risk protection hook for Uniswap v4 stable pools.
contract OscillonHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using FixedPointMathLib for uint256;

    event DepegDetected(
        PoolId indexed poolId,
        uint256 depegBps,
        uint24 feeApplied,
        uint256 swapSize,
        bool isDrain,
        bool usingFallback
    );
    event PoolRegistered(
        PoolId indexed poolId,
        address token0,
        address token1,
        address chainlink0,
        address chainlink1
    );
    event AdapterApproved(address indexed adapter);
    event AdapterRevoked(address indexed adapter);
    event ChainlinkOracleUpdated(
        PoolId indexed poolId,
        bool isToken0,
        address adapter
    );
    event ProtocolFeesCollected(PoolId indexed poolId, uint256 amount);
    event ProtocolTreasuryUpdated(address newTreasury);
    event OwnershipTransferred(
        address indexed oldOwner,
        address indexed newOwner
    );

    address public owner;
    address public protocolTreasury;

    mapping(address => bool) public approvedAdapters;
    mapping(PoolId => PoolConfig) public poolConfigs;
    mapping(PoolId => TwapState) internal twapStates;
    mapping(PoolId => uint256) public rollingDrain;
    mapping(PoolId => uint256) public rollingWindowStart;

    constructor(
        IPoolManager _poolManager,
        address initialOwner
    ) BaseHook(_poolManager) {
        if (initialOwner == address(0)) revert ZeroAddress();
        owner = initialOwner;
        protocolTreasury = initialOwner;
    }

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: true,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    // ── TWAP storage accessors (tests / monitoring) ───────────────────────────

    function obsCardinality(PoolId poolId) external view returns (uint16) {
        return twapStates[poolId].obsCardinality;
    }

    function obsIndex(PoolId poolId) external view returns (uint16) {
        return twapStates[poolId].obsIndex;
    }

    function observations(
        PoolId poolId,
        uint16 idx
    )
        external
        view
        returns (uint32 blockTimestamp, int56 tickCumulative, bool initialized)
    {
        Observation memory obs = twapStates[poolId].observations[idx];
        return (obs.blockTimestamp, obs.tickCumulative, obs.initialized);
    }

    // ── Pool registration ─────────────────────────────────────────────────────

    function registerPool(
        PoolKey calldata key,
        address chainlinkAdapter0,
        address chainlinkAdapter1,
        uint8 stableDecimals0,
        uint8 stableDecimals1
    ) external onlyOwner {
        if (key.tickSpacing != 1) revert NotStablePool();
        if (!approvedAdapters[chainlinkAdapter0])
            revert AdapterNotApproved(chainlinkAdapter0);
        if (!approvedAdapters[chainlinkAdapter1])
            revert AdapterNotApproved(chainlinkAdapter1);
        if (chainlinkAdapter0 == address(0) || chainlinkAdapter1 == address(0))
            revert ZeroAddress();

        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        if (token0 == token1) revert SameStable();

        PoolId poolId = key.toId();
        if (poolConfigs[poolId].registered) revert PoolAlreadyRegistered();

        poolConfigs[poolId] = PoolConfig({
            registered: true,
            token0: token0,
            token1: token1,
            oracles0: TokenOracleConfig({chainlinkAdapter: chainlinkAdapter0}),
            oracles1: TokenOracleConfig({chainlinkAdapter: chainlinkAdapter1}),
            maxDepegSwap0: C.MAX_DEPEG_SWAP_FACTOR *
                (10 ** uint256(stableDecimals0)),
            maxDepegSwap1: C.MAX_DEPEG_SWAP_FACTOR *
                (10 ** uint256(stableDecimals1)),
            lastHighDepegAt: 0,
            surplusAccrued: 0,
            protocolAccrued: 0
        });

        emit PoolRegistered(
            poolId,
            token0,
            token1,
            chainlinkAdapter0,
            chainlinkAdapter1
        );
    }

    /// @notice Replace a pool's Chainlink adapter after deployment (e.g. feed migration).
    function updatePoolChainlinkOracle(
        PoolKey calldata key,
        bool isToken0,
        address newChainlinkAdapter
    ) external onlyOwner {
        if (!approvedAdapters[newChainlinkAdapter])
            revert AdapterNotApproved(newChainlinkAdapter);
        PoolConfig storage cfg = poolConfigs[key.toId()];
        if (!cfg.registered) revert PoolNotRegistered();

        TokenOracleConfig storage oracles = isToken0
            ? cfg.oracles0
            : cfg.oracles1;
        oracles.chainlinkAdapter = newChainlinkAdapter;

        emit ChainlinkOracleUpdated(key.toId(), isToken0, newChainlinkAdapter);
    }

    // ── Hook callbacks ────────────────────────────────────────────────────────

    function _beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();
        PoolConfig storage cfg = poolConfigs[poolId];

        if (!cfg.registered) {
            return (
                this.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                C.BASE_FEE_PIPS | LPFeeLibrary.OVERRIDE_FEE_FLAG
            );
        }

        SwapContext memory ctx = _buildSwapContext(key, cfg, params);

        if (params.amountSpecified > 0 && ctx.depegBps >= C.SMALL_DEPEG_BPS) {
            revert ExactOutputDisabledDuringDepeg(ctx.depegBps);
        }

        uint128 liquidity = poolManager.getLiquidity(poolId);
        uint256 maxAbsolute = ctx.tokenInIsToken0
            ? cfg.maxDepegSwap0
            : cfg.maxDepegSwap1;
        uint256 cap = _min(maxAbsolute, (uint256(liquidity) * 50) / 10_000);
        if (
            ctx.isDrain &&
            ctx.depegBps >= C.CAP_DEPEG_BPS &&
            ctx.swapSize > cap
        ) revert SwapCapExceeded();

        uint24 fee = _selectFee(poolId, cfg, ctx);

        emit DepegDetected(
            poolId,
            ctx.depegBps,
            fee,
            ctx.swapSize,
            ctx.isDrain,
            ctx.usingFallback
        );

        return (
            this.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            fee | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    function _afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24
    ) internal override returns (bytes4) {
        OscillonTwapOracle.seed(twapStates[key.toId()]);
        return this.afterInitialize.selector;
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        PoolId poolId = key.toId();
        if (poolConfigs[poolId].registered) {
            (, int24 currentTick, , ) = poolManager.getSlot0(poolId);
            OscillonTwapOracle.write(twapStates[poolId], currentTick);
        }
        return (this.afterSwap.selector, int128(0));
    }

    // ── Swap context & fee ────────────────────────────────────────────────────

    function _buildSwapContext(
        PoolKey calldata key,
        PoolConfig storage cfg,
        SwapParams calldata params
    ) internal view returns (SwapContext memory ctx) {
        bool tokenInIsToken0 = params.zeroForOne;
        address tokenIn = tokenInIsToken0 ? cfg.token0 : cfg.token1;

        if (tokenIn != cfg.token0 && tokenIn != cfg.token1)
            revert UnsupportedToken(tokenIn);

        TokenOracleConfig memory tokenOracles = tokenInIsToken0
            ? cfg.oracles0
            : cfg.oracles1;
        uint256 twapPrice = OscillonTwapOracle.readTwapOrSpot(
            poolManager,
            key,
            twapStates[key.toId()]
        );
        PriceResult memory price = OscillonPriceEngine.getSellTokenPrice(
            tokenOracles,
            twapPrice
        );

        uint256 swapSize = params.amountSpecified < 0
            ? uint256(-params.amountSpecified)
            : uint256(params.amountSpecified);

        ctx = SwapContext({
            depegBps: price.depegBps,
            isDrain: price.pegBelow,
            usingFallback: price.usingFallback,
            priceSource: price.source,
            amountSpecified: params.amountSpecified,
            swapSize: swapSize,
            tokenInIsToken0: tokenInIsToken0
        });
    }

    function _selectFee(
        PoolId poolId,
        PoolConfig storage cfg,
        SwapContext memory ctx
    ) internal returns (uint24 fee) {
        bool inRestoreWindow = cfg.lastHighDepegAt != 0 &&
            (block.timestamp - cfg.lastHighDepegAt) <= C.RESTORE_WINDOW;

        if (ctx.depegBps < C.SMALL_DEPEG_BPS) {
            if (inRestoreWindow && ctx.depegBps == 0 && !ctx.isDrain)
                return C.RESTORE_FEE_PIPS;
            return C.BASE_FEE_PIPS;
        }

        cfg.lastHighDepegAt = block.timestamp;
        if (!ctx.isDrain) return C.BASE_FEE_PIPS;

        uint256 k = OscillonFeePolicy.kForLiquidity();
        uint256 feeBps = OscillonFeePolicy.hybridFeeBps(ctx.depegBps, k);
        uint256 mult = _rollingMultiplier(poolId, ctx.swapSize, true);
        uint24 surcharge = OscillonFeePolicy.depegSurchargePips(
            feeBps,
            ctx.usingFallback,
            ctx.depegBps,
            mult
        );
        fee = OscillonFeePolicy.totalFeePips(C.BASE_FEE_PIPS, surcharge);

        if (surcharge > 0) {
            uint256 surplusBps = uint256(surcharge) / 100;
            uint256 surplusAmount = ctx.swapSize.mulDivUp(surplusBps, 10_000);
            uint256 protocolCut = surplusAmount.mulDivUp(
                C.PROTOCOL_FEE_BPS,
                100
            );
            cfg.surplusAccrued += surplusAmount - protocolCut;
            cfg.protocolAccrued += protocolCut;
        }

        return fee;
    }

    function _rollingMultiplier(
        PoolId poolId,
        uint256 swapSize,
        bool isDrain
    ) internal returns (uint256) {
        if (block.number > rollingWindowStart[poolId] + C.ROLLING_BLOCKS) {
            rollingDrain[poolId] = 0;
            rollingWindowStart[poolId] = block.number;
        }

        if (isDrain) rollingDrain[poolId] += swapSize;

        uint128 liquidity = poolManager.getLiquidity(poolId);
        if (liquidity == 0) return 100;

        uint256 drainPct = (rollingDrain[poolId] * 10_000) / uint256(liquidity);
        return OscillonFeePolicy.rollingMultiplier(drainPct);
    }

    // ── Views ─────────────────────────────────────────────────────────────────

    function getPoolState(
        PoolKey calldata key
    )
        external
        view
        returns (
            bool registered,
            uint256 depegBps0,
            bool pegBelow0,
            bool usingFallback0,
            uint256 depegBps1,
            bool pegBelow1,
            bool usingFallback1,
            bool inRestoreWindow,
            uint256 surplusAccrued,
            uint256 protocolAccrued
        )
    {
        PoolConfig storage cfg = poolConfigs[key.toId()];
        registered = cfg.registered;
        surplusAccrued = cfg.surplusAccrued;
        protocolAccrued = cfg.protocolAccrued;
        inRestoreWindow =
            cfg.lastHighDepegAt != 0 &&
            (block.timestamp - cfg.lastHighDepegAt) <= C.RESTORE_WINDOW;

        if (!cfg.registered) {
            return (false, 0, false, false, 0, false, false, false, 0, 0);
        }

        (depegBps0, pegBelow0, usingFallback0, depegBps1, pegBelow1, usingFallback1) =
            _poolOracleSnapshot(key, cfg);
    }

    function _poolOracleSnapshot(PoolKey calldata key, PoolConfig storage cfg)
        internal
        view
        returns (
            uint256 depegBps0,
            bool pegBelow0,
            bool usingFallback0,
            uint256 depegBps1,
            bool pegBelow1,
            bool usingFallback1
        )
    {
        PoolId poolId = key.toId();
        uint256 twapPrice = OscillonTwapOracle.readTwapOrSpot(
            poolManager,
            key,
            twapStates[poolId]
        );

        PriceResult memory price0 =
            OscillonPriceEngine.getSellTokenPrice(cfg.oracles0, twapPrice);
        PriceResult memory price1 =
            OscillonPriceEngine.getSellTokenPrice(cfg.oracles1, twapPrice);

        depegBps0 = price0.depegBps;
        pegBelow0 = price0.pegBelow;
        usingFallback0 = price0.usingFallback;
        depegBps1 = price1.depegBps;
        pegBelow1 = price1.pegBelow;
        usingFallback1 = price1.usingFallback;
    }

    function getPoolConfig(
        PoolKey calldata key
    ) external view returns (PoolConfig memory) {
        return poolConfigs[key.toId()];
    }

    // ── Protocol fees & governance ──────────────────────────────────────────

    function collectProtocolFees(
        PoolKey calldata key,
        address token
    ) external onlyOwner {
        PoolId id = key.toId();
        PoolConfig storage cfg = poolConfigs[id];
        if (!cfg.registered) revert PoolNotRegistered();

        uint256 amount = cfg.protocolAccrued;
        if (amount == 0) return;
        cfg.protocolAccrued = 0;

        if (!IERC20(token).transfer(protocolTreasury, amount))
            revert TransferFailed();
        emit ProtocolFeesCollected(id, amount);
    }

    function approveAdapter(address adapter) external onlyOwner {
        if (adapter == address(0)) revert ZeroAddress();
        try IOscillonOracle(adapter).isHealthy() returns (bool) {
            approvedAdapters[adapter] = true;
            emit AdapterApproved(adapter);
        } catch {
            approvedAdapters[adapter] = true;
            emit AdapterApproved(adapter);
        }
    }

    function revokeAdapter(address adapter) external onlyOwner {
        approvedAdapters[adapter] = false;
        emit AdapterRevoked(adapter);
    }

    function setProtocolTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        protocolTreasury = newTreasury;
        emit ProtocolTreasuryUpdated(newTreasury);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }
}
