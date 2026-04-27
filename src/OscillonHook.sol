// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-hooks-public/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IAggregatorV3Interface} from "./interface/IAggregatorV3Interface.sol";

// ─── Errors ──────────────────────────────────────────────────────────────────

error NotOwner();
error PoolNotRegistered();
error PoolAlreadyRegistered();
error UnsupportedToken(address token);
error OracleAnswerInvalid();
error OracleStale(uint256 updatedAt, uint256 blockTime);
error OracleRoundIncomplete(uint80 roundId, uint80 answeredInRound);
error ZeroAddress();
error SameStable();

contract OscillonHook is BaseHook {
    using PoolIdLibrary for PoolKey;

    // ── Events ───────────────────────────────────────────────────────────────

    /// @notice Emitted on every swap — useful for dashboard indexing.
    event DepegDetected(PoolId indexed poolId, uint256 depegBps, uint24 feeApplied, uint256 swapSize, bool isDrain);

    /// @notice Emitted when owner registers a new stable pool.
    event PoolRegistered(PoolId indexed poolId, address token0, address token1, address oracle0, address oracle1);

    /// @notice Emitted when pool config is updated (oracle change etc).
    event PoolUpdated(PoolId indexed poolId);

    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ── Governance ───────────────────────────────────────────────────────────

    address public owner;

    // ── Fee constants (in Uniswap v4 pips — 1 bps = 100 pips) ───────────────

    uint24 public constant BASE_FEE_PIPS = 100; // 1 bps   — healthy pool
    uint24 public constant SMALL_FEE_PIPS = 800; // 8 bps   — micro-depeg
    uint24 public constant DRAIN_FEE_PIPS = 2800; // 28 bps  — drain direction
    uint24 public constant RESTORE_FEE_PIPS = 30; // 0.3 bps — restore reward

    /// @notice v2: replaces PoolFrozen revert.
    /// Severe depeg → fee capped here instead of freezing.
    /// Pool keeps running. LPs still protected by high cost of arb.
    uint24 public constant MAX_FEE_PIPS = 5000; // 50 bps  — severe depeg cap
    
    // ── Depeg thresholds (bps) ────────────────────────────────────────────────

    uint256 public constant SMALL_DEPEG_BPS = 7;
    uint256 public constant DRAIN_DEPEG_BPS = 25;

    /// @notice v2: no freeze at this threshold — fee just hits MAX_FEE_PIPS.
    uint256 public constant SEVERE_DEPEG_BPS = 50;

    // ── Timing ────────────────────────────────────────────────────────────────

    uint256 public constant RESTORE_WINDOW = 1 hours;
    uint256 public constant MAX_ORACLE_AGE = 2 minutes;

    // ── Swap size cap factor ──────────────────────────────────────────────────

    uint256 public constant MAX_DEPEG_SWAP_FACTOR = 50_000; // $50k default cap

    // ── Per-pool configuration ────────────────────────────────────────────────

    /// @notice
    /// v2 CORE CHANGE: all previously-immutable oracle/stable config
    /// is now stored here per-pool. Each PoolId gets its own config.
    /// A single deployed hook contract serves all registered pools.
    struct PoolConfig {
        // Is this pool registered with Oscillon?
        bool registered;
        // token0 of the pool (e.g. USDC)
        address token0;
        // token1 of the pool (e.g. USDT)
        address token1;
        // Chainlink oracle for token0/USD (e.g. USDC/USD feed)
        address oracle0;
        // Chainlink oracle for token1/USD (e.g. USDT/USD feed)
        address oracle1;
        // Decimal precision of oracle0 answer (usually 8)
        uint8 oracle0Decimals;
        // Decimal precision of oracle1 answer (usually 8)
        uint8 oracle1Decimals;
        // Max exact-in swap size during drain (per-pool, based on decimals)
        uint256 maxDepegSwap0;
        uint256 maxDepegSwap1;
        // Last timestamp this pool hit SMALL_DEPEG_BPS or above
        // Used for restore window tracking
        uint256 lastHighDepegAt;
        // Accrued fee surplus for LP redistribution (Phase 2)
        uint256 surplusAccrued;
    }

    struct SwapContext {
        uint256 depegBps;
        bool isDrain;
        int256 amountSpecified;
        uint256 swapSize;
        bool tokenInIsToken0;
    }

    /// @notice The registry. One hook → many pools.
    mapping(PoolId => PoolConfig) public poolConfigs;

    // ── Constructor ───────────────────────────────────────────────────────────

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {
        owner = msg.sender;
    }

    // ── Hook permissions ──────────────────────────────────────────────────────

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ── Pool registration ─────────────────────────────────────────────────────

    /// @notice Register a stable pair with its oracle feeds.
    ///         Call this once per pool after hook deployment.
    ///
    /// @dev    v2 CORE FUNCTION — replaces constructor oracle hardcoding.
    ///
    /// Example calls:
    ///   registerPool(usdcUsdtKey, CHAINLINK_USDC_USD, CHAINLINK_USDT_USD, 6, 6)
    ///   registerPool(usdcDaiKey,  CHAINLINK_USDC_USD, CHAINLINK_DAI_USD,  6, 18)
    ///   registerPool(usdtDaiKey,  CHAINLINK_USDT_USD, CHAINLINK_DAI_USD,  6, 18)
    ///   registerPool(usdcCrvKey,  CHAINLINK_USDC_USD, CHAINLINK_CRVUSD_USD, 6, 18)
    ///
    /// @param key              PoolKey of the stable pair to protect
    /// @param oracle0          Chainlink feed address for token0/USD
    /// @param oracle1          Chainlink feed address for token1/USD
    /// @param stableDecimals0  ERC20 decimals of token0 (for swap cap math)
    /// @param stableDecimals1  ERC20 decimals of token1 (for swap cap math)

    function registerPool(
        PoolKey calldata key,
        address oracle0,
        address oracle1,
        uint8 stableDecimals0,
        uint8 stableDecimals1
    ) external onlyOwner {
        if (oracle0 == address(0) || oracle1 == address(0)) {
            revert ZeroAddress();
        }

        address t0 = Currency.unwrap(key.currency0);
        address t1 = Currency.unwrap(key.currency1);
        if (t0 == t1) revert SameStable();

        PoolId id = key.toId();
        if (poolConfigs[id].registered) revert PoolAlreadyRegistered();

        // Cache oracle decimals at registration — saves a call on every swap
        uint8 dec0 = IAggregatorV3Interface(oracle0).decimals();
        uint8 dec1 = IAggregatorV3Interface(oracle1).decimals();

        poolConfigs[id] = PoolConfig({
            registered: true,
            token0: t0,
            token1: t1,
            oracle0: oracle0,
            oracle1: oracle1,
            oracle0Decimals: dec0,
            oracle1Decimals: dec1,
            maxDepegSwap0: MAX_DEPEG_SWAP_FACTOR * (10 ** uint256(stableDecimals0)),
            maxDepegSwap1: MAX_DEPEG_SWAP_FACTOR * (10 ** uint256(stableDecimals1)),
            lastHighDepegAt: 0,
            surplusAccrued: 0
        });

        emit PoolRegistered(id, t0, t1, oracle0, oracle1);
    }

    /// @notice Update oracle addresses for a registered pool.
    ///         Use if Chainlink deprecates a feed.
    function updatePoolOracles(PoolKey calldata key, address newOracle0, address newOracle1) external onlyOwner {
        require(IAggregatorV3Interface(newOracle0).decimals() > 0, "Invalid oracle");
        require(IAggregatorV3Interface(newOracle1).decimals() > 0, "Invalid oracle");
        PoolId id = key.toId();
        if (!poolConfigs[id].registered) revert PoolNotRegistered();
        if (newOracle0 == address(0) || newOracle1 == address(0)) {
            revert ZeroAddress();
        }

        PoolConfig storage cfg = poolConfigs[id];

        cfg.oracle0 = newOracle0;
        cfg.oracle1 = newOracle1;
        cfg.oracle0Decimals = IAggregatorV3Interface(newOracle0).decimals();
        cfg.oracle1Decimals = IAggregatorV3Interface(newOracle1).decimals();

        emit PoolUpdated(id);
    }

    // ── beforeSwap — core logic ───────────────────────────────────────────────

    /// @notice Runs before every swap in every registered pool.
    ///
    /// FLOW:
    ///   1. Load pool config — skip unregistered pools silently
    ///   2. Identify which token is being sold (tokenIn)
    ///   3. Read oracle for tokenIn only (directional asymmetry)
    ///   4. Calculate deviation in bps
    ///   5. Calculate final fee based on direction + deviation
    ///   6. Return fee | OVERRIDE_FEE_FLAG
    ///
    /// NOTE on unregistered pools:
    ///   If _beforeSwap is called for a pool that isn't registered,
    ///   we return BASE_FEE silently — the hook gracefully does nothing.
    ///   This prevents reverts on any pool that happens to use this hook address.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        PoolConfig storage cfg = poolConfigs[id];

        // ── 1. Unregistered pool → pass through at base fee
        if (!cfg.registered) {
            return (
                this.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                BASE_FEE_PIPS | LPFeeLibrary.OVERRIDE_FEE_FLAG
            );
        }
        SwapContext memory ctx = _buildSwapContext(cfg, params);

        uint24 fee = _selectFee(cfg, ctx);

        emit DepegDetected(id, ctx.depegBps, fee, ctx.swapSize, ctx.isDrain);

        // ── 7. Return fee with OVERRIDE_FEE_FLAG
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function _buildSwapContext(PoolConfig storage cfg, SwapParams calldata params)
        internal
        view
        returns (SwapContext memory ctx)
    {
        // zeroForOne = true  -> tokenIn is token0
        // zeroForOne = false -> tokenIn is token1
        bool tokenInIsToken0 = params.zeroForOne;
        address tokenIn = tokenInIsToken0 ? cfg.token0 : cfg.token1;
        if (tokenIn != cfg.token0 && tokenIn != cfg.token1) {
            revert UnsupportedToken(tokenIn);
        }

        address oracleAddr = tokenInIsToken0 ? cfg.oracle0 : cfg.oracle1;
        uint8 oracleDec = tokenInIsToken0 ? cfg.oracle0Decimals : cfg.oracle1Decimals;
        (uint256 depegBps, bool pegBelow) = _readDepeg(oracleAddr, oracleDec);
        uint256 swapSize =
            params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        ctx = SwapContext({
            depegBps: depegBps,
            isDrain: pegBelow,
            amountSpecified: params.amountSpecified,
            swapSize: swapSize,
            tokenInIsToken0: tokenInIsToken0
        });
        return ctx;
    }

    // ── Fee selection ─────────────────────────────────────────────────────────

    /// @notice Computes the final fee for a swap.
    ///
    /// Fee ladder:
    ///
    ///   No depeg:
    ///     → BASE_FEE_PIPS (1 bps)
    ///
    ///   Restore direction (buying the depegged token):
    ///     → RESTORE_FEE_PIPS (0.3 bps) — cheaper than anywhere
    ///     → OR restore window active after recent depeg → RESTORE_FEE_PIPS
    ///
    ///   Drain direction (selling depegged token in):
    ///     → SMALL (8 bps)   if 7 bps  <= depeg < 20 bps
    ///     → DRAIN (28 bps)  if 20 bps <= depeg < 50 bps
    ///     → MAX   (50 bps)  if depeg >= 50 bps  [v2: replaces PoolFrozen revert]
    ///
    ///   Large drain (>$50k during depeg):
    ///     → additional swap size cap applied

    // test this each line
    function _selectFee(PoolConfig storage cfg, SwapContext memory ctx) internal returns (uint24 fee) {
        // ── Restore window check ──────────────────────────────────────────────
        bool inRestoreWindow = cfg.lastHighDepegAt != 0 && (block.timestamp - cfg.lastHighDepegAt) <= RESTORE_WINDOW;
        // ── Healthy pool — no depeg ───────────────────────────────────────────

        if (ctx.depegBps < SMALL_DEPEG_BPS) {
            // If we are in the restore window (recently resolved depeg)
            // and this is a restore-direction swap → discount
            if (inRestoreWindow && !ctx.isDrain) {
                return RESTORE_FEE_PIPS;
            }
            return BASE_FEE_PIPS;
        }

        // ── Active depeg — update last high timestamp ─────────────────────────
        // Track from SMALL tier so restore window fires correctly for any depeg.
        cfg.lastHighDepegAt = block.timestamp;

        // ── Restore direction — give discount ─────────────────────────────────
        // Even during an active depeg, swaps going the "right" direction
        // (buying the depegged token) get the restore discount.
        // This attracts aggregator flow and helps pool rebalance naturally.

        if (!ctx.isDrain) {
            return RESTORE_FEE_PIPS;
        }

        // ── Drain direction — graduated fee ───────────────────────────────────
        //
        // v2 CHANGE: no PoolFrozen revert at SEVERE_DEPEG_BPS.
        // Instead: fee hits MAX_FEE_PIPS (50 bps) and stays there.
        // Pool keeps running. Arb is expensive but not impossible.
        // LPs protected by high cost. No permanently bricked pools.
        if (ctx.depegBps >= SEVERE_DEPEG_BPS) {
            fee = MAX_FEE_PIPS; // 50 bps — severe depeg cap
        } else if (ctx.depegBps >= DRAIN_DEPEG_BPS) {
            fee = DRAIN_FEE_PIPS; // 28 bps
        } else {
            fee = SMALL_FEE_PIPS; // 8 bps
        }

        // ── Large swap cap during drain ───────────────────────────────────────
        // Only applies to exact-in swaps above the size threshold.
        // Retail swaps (<$50k) never hit this.
        uint256 maxSwap = ctx.tokenInIsToken0 ? cfg.maxDepegSwap0 : cfg.maxDepegSwap1;
        if (ctx.amountSpecified < 0 && ctx.swapSize > maxSwap) {
            // Cap the swap size — excess reverts
            // In production this uses BeforeSwapDelta to limit input
            // For MVP: simple require
            require(ctx.swapSize <= maxSwap, "Oscillon: drain swap exceeds size limit");
        }
        // Accrue surplus for LP redistribution
        if (fee > BASE_FEE_PIPS) {
            uint256 surplusBps = uint256(fee / 100) - 1; // surplus above 1 bps
            uint256 surplusAmount = (ctx.swapSize * surplusBps) / 10_000;
            cfg.surplusAccrued += (surplusAmount * 85) / 100; // 85% to LPs, 15% protocol
        }

        return fee;
    }

    // ── Oracle read ───────────────────────────────────────────────────────────

    /// @notice Reads a Chainlink feed and returns deviation from $1 peg.
    /// @return depegBps  Deviation in basis points
    /// @return pegBelow  True if token is trading below $1
    function _readDepeg(address oracleAddr, uint8 oracleDec) internal view returns (uint256 depegBps, bool pegBelow) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            IAggregatorV3Interface(oracleAddr).latestRoundData();

        if (answer <= 0) revert OracleAnswerInvalid();
        if (answeredInRound < roundId) {
            revert OracleRoundIncomplete(roundId, answeredInRound);
        }
        if (block.timestamp > updatedAt + MAX_ORACLE_AGE) {
            revert OracleStale(updatedAt, block.timestamp);
        }

        // Normalise to 1e18. $1.0000 = 1e18.

        /**
         *  0.89 / 18
         */
        uint256 price1e18 = (uint256(answer) * 1e18) / (10 ** uint256(oracleDec));

        pegBelow = price1e18 < 1e18;
        depegBps = pegBelow ? ((1e18 - price1e18) * 10_000) / 1e18 : ((price1e18 - 1e18) * 10_000) / 1e18;
    }

    // ── View helpers ──────────────────────────────────────────────────────────

    /// @notice Read the current state of any registered pool.
    ///         Used by the Oscillon dashboard.
    function getPoolState(PoolKey calldata key)
        external
        view
        returns (
            bool registered,
            uint256 depegBps0,
            bool pegBelow0,
            uint256 depegBps1,
            bool pegBelow1,
            bool inRestoreWindow,
            uint256 surplusAccrued
        )
    {
        PoolId id = key.toId();
        PoolConfig storage cfg = poolConfigs[id];

        registered = cfg.registered;
        surplusAccrued = cfg.surplusAccrued;
        inRestoreWindow = cfg.lastHighDepegAt != 0 && (block.timestamp - cfg.lastHighDepegAt) <= RESTORE_WINDOW;

        if (!cfg.registered) return (false, 0, false, 0, false, false, 0);

        (depegBps0, pegBelow0) = _readDepeg(cfg.oracle0, cfg.oracle0Decimals);
        (depegBps1, pegBelow1) = _readDepeg(cfg.oracle1, cfg.oracle1Decimals);
    }

    /// @notice Returns all config for a pool — useful for integrators.
    function getPoolConfig(PoolKey calldata key) external view returns (PoolConfig memory) {
        return poolConfigs[key.toId()];
    }

    // ── Governance ────────────────────────────────────────────────────────────

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}
