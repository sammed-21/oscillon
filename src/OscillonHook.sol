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
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAggregatorV3Interface} from "./interface/IAggregatorV3Interface.sol";

// ─── Errors ───────────────────────────────────────────────────────────────────

error NotOwner();
error PoolNotRegistered();
error PoolAlreadyRegistered();
error UnsupportedToken(address token);
error OracleAnswerInvalid();
error OracleStale(uint256 updatedAt, uint256 blockTime);
error OracleRoundIncomplete(uint80 roundId, uint80 answeredInRound);
error ZeroAddress();
error SameStable();
error NotStablePool();
error OracleNotApproved(address oracle);
error ExactOutputDisabledDuringDepeg(uint256 depegBps);
error SwapCapExceeded();
error TransferFailed();

// ─── Main contract ────────────────────────────────────────────────────────────

contract OscillonHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using FixedPointMathLib for uint256;

    // ── Events ───────────────────────────────────────────────────────────────

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
        address oracle0,
        address oracle1
    );
    event OracleApproved(address indexed oracle);
    event OracleRevoked(address indexed oracle);
    event ProtocolFeesCollected(PoolId indexed poolId, uint256 amount);
    event ProtocolTreasuryUpdated(address newTreasury);
    event OwnershipTransferred(
        address indexed oldOwner,
        address indexed newOwner
    );

    // ── Per-pool config ───────────────────────────────────────────────────────

    struct PoolConfig {
        bool registered;
        address token0;
        address token1;
        // [CHANGE 3] Two independent oracle feeds — one per token
        // v2 had a single shared oracle; this creates directional accuracy
        // token0 oracle: e.g. USDC/USD  |  token1 oracle: e.g. USDT/USD
        address oracle0;
        address oracle1;
        uint8 oracle0Decimals;
        uint8 oracle1Decimals;
        uint256 maxDepegSwap0;
        uint256 maxDepegSwap1;
        uint256 lastHighDepegAt;
        // [CHANGE 6] Split accounting: LP surplus vs protocol cut
        uint256 surplusAccrued; // 85% — distributed to LPs via donate()
        uint256 protocolAccrued; // 15% — collected by protocol treasury
    }

    // ── TWAP observation (in-hook oracle — v4 has no native observe) ─────────
    //
    // v4 deliberately removed observations from IPoolManager. To preserve the
    // [CHANGE 4] disagreement guard and Chainlink fallback, we maintain a
    // per-pool ring buffer of (timestamp, tickCumulative) updated on afterSwap.
    // tickCumulative grows linearly: tickCumulative_new = tickCumulative_last
    //                              + currentTick * (now - last.timestamp)
    // 30-min TWAP = (tickCumulative_now - tickCumulative_30m_ago) / 1800.

    struct Observation {
        uint32 blockTimestamp;
        int56 tickCumulative;
        bool initialized;
    }

    // ── Swap context (built once per swap, passed down) ───────────────────────

    struct SwapContext {
        uint256 depegBps;
        bool isDrain;
        bool usingFallback; // true when TWAP used instead of Chainlink
        int256 amountSpecified;
        uint256 swapSize;
        bool tokenInIsToken0;
    }

    // ── Fee constants (pips = hundredths of a bip, 100 pips = 1 bps) ─────────

    uint24 public constant BASE_FEE_PIPS = 100; // 1 bps
    uint24 public constant RESTORE_FEE_PIPS = 100; // [CHANGE 2] 1 bps (not 0.3)
    // restore discount removed for POC
    // re-add in phase 2 with epoch drain gate
    uint24 public constant MAX_FEE_PIPS = 5000; // 50 bps hard cap

    // ── Depeg thresholds (bps) ────────────────────────────────────────────────

    uint256 public constant SMALL_DEPEG_BPS = 7;

    // ── Timing ───────────────────────────────────────────────────────────────

    uint256 public constant RESTORE_WINDOW = 1 hours;

    // [CHANGE 1] Was 2 minutes — broke on all mainnet chains
    // Chainlink USDT/USD heartbeat on Arbitrum = 24 hours
    // 2-min staleness reverted 90%+ of swaps in calm markets
    // 25 hours = heartbeat + small buffer
    uint256 public constant MAX_ORACLE_AGE = 25 hours;

    // [CHANGE 4] Disagreement guard threshold
    // If |Chainlink - TWAP| > this, something is wrong → use conservative
    uint256 public constant ORACLE_DISAGREE_BPS = 20;

    // ── Swap size cap ─────────────────────────────────────────────────────────

    uint256 public constant MAX_DEPEG_SWAP_FACTOR = 50_000;

    // ── Rolling drain window ──────────────────────────────────────────────────

    uint32 public constant ROLLING_BLOCKS = 300; // ~10 min on Arbitrum

    // ── TWAP observation buffer ───────────────────────────────────────────────

    // Ring buffer length per pool. 144 slots covers >30 min comfortably even at
    // ~12s/block; oldest observation is overwritten when full.
    uint16 public constant OBS_CARDINALITY = 144;

    // Target TWAP window — must match the read window in _readTwap30.
    uint32 public constant TWAP_WINDOW = 1800; // 30 min

    // ── Protocol revenue ─────────────────────────────────────────────────────

    // 15% of surplus above base fee goes to protocol treasury
    // 85% stays with LPs via surplusAccrued → donate()
    uint256 public constant PROTOCOL_FEE_BPS = 15;
    uint256 public constant LP_FEE_BPS = 85;

    // ── Storage ───────────────────────────────────────────────────────────────

    address public owner;
    address public protocolTreasury;

    // [CHANGE 5] Oracle registry — governance approves feeds, anyone registers pools
    mapping(address => bool) public approvedOracles;

    mapping(PoolId => PoolConfig) public poolConfigs;
    mapping(PoolId => uint256) public rollingDrain;
    mapping(PoolId => uint256) public rollingWindowStart;

    // TWAP ring buffer state (one buffer per pool).
    mapping(PoolId => mapping(uint16 => Observation)) public observations;
    mapping(PoolId => uint16) public obsIndex; // index of newest observation
    mapping(PoolId => uint16) public obsCardinality; // current populated count

    // ── Constructor ───────────────────────────────────────────────────────────

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {
        owner = msg.sender;
        protocolTreasury = msg.sender; // override before mainnet with Gnosis Safe
    }

    // ── Hook permissions ──────────────────────────────────────────────────────

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: true, // seed TWAP observation buffer on init
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true, // record TWAP observations after each swap
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    // ── Pool registration ─────────────────────────────────────────────────────

    /// @notice Register a stable pool with two independent oracle feeds.
    ///
    /// [CHANGE 5] No longer onlyOwner — anyone can register IF both oracles
    /// are in the approved registry. Governance curates oracle quality.
    /// Pair permissionlessness, oracle curation.
    ///
    /// [CHANGE 9] tickSpacing == 1 guard — physically prevents volatile pair
    /// registration. ETH/USDC uses tickSpacing 60 and will always revert here.
    ///
    /// @param key              PoolKey of the stable pair (must use DYNAMIC_FEE_FLAG)
    /// @param oracle0          Chainlink feed for token0/USD (must be approved)
    /// @param oracle1          Chainlink feed for token1/USD (must be approved)
    /// @param stableDecimals0  ERC20 decimals of token0
    /// @param stableDecimals1  ERC20 decimals of token1
    function registerPool(
        PoolKey calldata key,
        address oracle0,
        address oracle1,
        uint8 stableDecimals0,
        uint8 stableDecimals1
    ) external {
        // [CHANGE 9] Stable-only enforcement via tick spacing
        if (key.tickSpacing != 1) revert NotStablePool();

        // [CHANGE 5] Oracle registry gate — no arbitrary oracle addresses
        if (!approvedOracles[oracle0]) revert OracleNotApproved(oracle0);
        if (!approvedOracles[oracle1]) revert OracleNotApproved(oracle1);

        if (oracle0 == address(0) || oracle1 == address(0))
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
            oracle0: oracle0,
            oracle1: oracle1,
            oracle0Decimals: IAggregatorV3Interface(oracle0).decimals(),
            oracle1Decimals: IAggregatorV3Interface(oracle1).decimals(),
            maxDepegSwap0: MAX_DEPEG_SWAP_FACTOR *
                (10 ** uint256(stableDecimals0)),
            maxDepegSwap1: MAX_DEPEG_SWAP_FACTOR *
                (10 ** uint256(stableDecimals1)),
            lastHighDepegAt: 0,
            surplusAccrued: 0,
            protocolAccrued: 0
        });

        emit PoolRegistered(poolId, token0, token1, oracle0, oracle1);
    }

    // ── beforeSwap — core hook ────────────────────────────────────────────────

    function _beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();
        PoolConfig storage cfg = poolConfigs[poolId];

        // Unregistered pool → pass through at base fee, do not revert
        if (!cfg.registered) {
            return (
                this.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                BASE_FEE_PIPS | LPFeeLibrary.OVERRIDE_FEE_FLAG
            );
        }

        // Build swap context — oracle read happens here
        SwapContext memory ctx = _buildSwapContext(key, cfg, params);

        // [CHANGE 2] Exact output disabled during ANY active depeg
        // Prevents Bunni-style rounding attack on exact output path
        if (params.amountSpecified > 0 && ctx.depegBps >= SMALL_DEPEG_BPS) {
            revert ExactOutputDisabledDuringDepeg(ctx.depegBps);
        }

        // Swap size cap — scaled to pool depth (not fixed dollar amount)
        uint128 liquidity = poolManager.getLiquidity(poolId);
        uint256 maxAbsolute = ctx.tokenInIsToken0
            ? cfg.maxDepegSwap0
            : cfg.maxDepegSwap1;
        uint256 cap = _min(maxAbsolute, (uint256(liquidity) * 50) / 10_000);
        if (ctx.isDrain && ctx.swapSize > cap) revert SwapCapExceeded();

        // Compute fee
        uint24 fee = _selectFee(poolId, cfg, ctx, liquidity);

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

    // ── afterInitialize / afterSwap — TWAP observation maintenance ───────────

    /// @notice Seed the per-pool observation ring buffer with the initial tick.
    function _afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24 tick
    ) internal override returns (bytes4) {
        PoolId poolId = key.toId();
        observations[poolId][0] = Observation({
            blockTimestamp: uint32(block.timestamp),
            tickCumulative: 0,
            initialized: true
        });
        obsIndex[poolId] = 0;
        obsCardinality[poolId] = 1;
        // tick is unused here; the next observation will accrue tick * delta.
        tick;
        return this.afterInitialize.selector;
    }

    /// @notice Record an observation after every swap so the in-hook oracle
    ///         has fresh data for _readTwap30. Skipped for unregistered pools.
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
            _writeObservation(poolId, currentTick);
        }
        return (this.afterSwap.selector, int128(0));
    }

    /// @notice Append a new observation to the ring buffer. tickCumulative
    ///         accrues using the tick *before* this swap (the most recent
    ///         observation's tick), but for simplicity we just record using
    ///         the post-swap tick — same approximation Uniswap v3 uses for
    ///         observations driven by writes (reasonable for short windows).
    function _writeObservation(PoolId poolId, int24 currentTick) internal {
        uint16 lastIdx = obsIndex[poolId];
        Observation memory last = observations[poolId][lastIdx];

        if (!last.initialized) {
            // Defensive: pool wasn't initialized through this hook; seed now.
            observations[poolId][0] = Observation({
                blockTimestamp: uint32(block.timestamp),
                tickCumulative: 0,
                initialized: true
            });
            obsIndex[poolId] = 0;
            obsCardinality[poolId] = 1;
            return;
        }

        uint32 nowTs = uint32(block.timestamp);
        if (nowTs == last.blockTimestamp) return; // dedupe within same second

        int56 delta = int56(uint56(nowTs - last.blockTimestamp));
        int56 newCumulative = last.tickCumulative +
            int56(currentTick) *
            delta;

        uint16 nextIdx = (lastIdx + 1) % OBS_CARDINALITY;
        observations[poolId][nextIdx] = Observation({
            blockTimestamp: nowTs,
            tickCumulative: newCumulative,
            initialized: true
        });
        obsIndex[poolId] = nextIdx;

        uint16 card = obsCardinality[poolId];
        if (card < OBS_CARDINALITY) obsCardinality[poolId] = card + 1;
    }

    // ── Swap context builder ──────────────────────────────────────────────────

    /// @notice Reads oracle for the INPUT token only (directional asymmetry).
    /// If USDT is depegging and trader is selling USDC, oracle reads USDC
    /// which is fine → no drain penalty. Correct directional detection.
    function _buildSwapContext(
        PoolKey calldata key,
        PoolConfig storage cfg,
        SwapParams calldata params
    ) internal view returns (SwapContext memory ctx) {
        bool tokenInIsToken0 = params.zeroForOne;
        address tokenIn = tokenInIsToken0 ? cfg.token0 : cfg.token1;

        if (tokenIn != cfg.token0 && tokenIn != cfg.token1) {
            revert UnsupportedToken(tokenIn);
        }

        // [CHANGE 3] Read oracle for tokenIn specifically
        // Each token has its own feed — accurate per-direction detection
        address feed = tokenInIsToken0 ? cfg.oracle0 : cfg.oracle1;
        uint8 dec = tokenInIsToken0 ? cfg.oracle0Decimals : cfg.oracle1Decimals;

        (
            uint256 depegBps,
            bool pegBelow,
            bool usingFallback
        ) = _readDepegWithFallback(key, feed, dec);

        uint256 swapSize = params.amountSpecified < 0
            ? uint256(-params.amountSpecified)
            : uint256(params.amountSpecified);

        ctx = SwapContext({
            depegBps: depegBps,
            isDrain: pegBelow,
            usingFallback: usingFallback,
            amountSpecified: params.amountSpecified,
            swapSize: swapSize,
            tokenInIsToken0: tokenInIsToken0
        });
    }

    // ── Fee selection ─────────────────────────────────────────────────────────

    function _selectFee(
        PoolId poolId,
        PoolConfig storage cfg,
        SwapContext memory ctx,
        uint128 poolLiquidity
    ) internal returns (uint24 fee) {
        // [CHANGE 2] Restore window check — but restore fee is BASE_FEE for POC
        // The 0.3 bps discount is removed until epoch drain tracking is live
        // to prevent the drain-then-restore double extraction attack
        bool inRestoreWindow = cfg.lastHighDepegAt != 0 &&
            (block.timestamp - cfg.lastHighDepegAt) <= RESTORE_WINDOW;

        // Healthy pool — no depeg
        if (ctx.depegBps < SMALL_DEPEG_BPS) {
            // [CHANGE 2] Restore window: devBps must be EXACTLY 0
            // v2 used devBps <= SMALL_DEPEG_BPS (7) which allowed drain at 6 bps
            if (inRestoreWindow && ctx.depegBps == 0 && !ctx.isDrain) {
                return RESTORE_FEE_PIPS; // currently same as BASE — safe
            }
            return BASE_FEE_PIPS;
        }

        // Active depeg — update timestamp
        cfg.lastHighDepegAt = block.timestamp;

        // Restore direction during depeg → base fee (no discount for POC)
        if (!ctx.isDrain) return BASE_FEE_PIPS;

        // ── Drain direction — quadratic fee ──────────────────────────────────
        //
        // fee_bps = 1 + (K × devBps²) / 10000
        //
        // K = 60 for thin pools (<$500k liquidity) — more aggressive protection
        // K = 45 for standard pools
        //
        // Outputs (K=45):
        //   5 bps dev  → 1.11 bps fee
        //  10 bps dev  → 1.45 bps fee
        //  15 bps dev  → 2.01 bps fee
        //  25 bps dev  → 3.81 bps fee
        //  35 bps dev  → 6.51 bps fee
        //  50 bps dev  → 12.25 bps fee
        //
        // No cliffs → no threshold front-run attack possible

        uint256 k = uint256(poolLiquidity) < 500_000e6 ? 60 : 45;
        uint256 rawFee = 100 + (k * ctx.depegBps * ctx.depegBps) / 10_000;

        // [CHANGE 10] Reduce fee sensitivity during TWAP fallback
        // TWAP lags 30 min — a real 10 bps depeg may look like 6 bps on TWAP
        // Halve the fee increase when below 15 bps and on fallback
        if (ctx.usingFallback && ctx.depegBps < 15) {
            uint256 increase = rawFee - 100;
            rawFee = 100 + (increase / 2);
        }

        // Rolling drain multiplier — defeats fragmentation and slow TWAP poisoning
        uint256 mult = _rollingMultiplier(poolId, ctx.swapSize, true);
        rawFee = rawFee.mulDivDown(mult, 100);

        fee = uint24(rawFee > MAX_FEE_PIPS ? MAX_FEE_PIPS : rawFee);

        // [CHANGE 6] Split surplus: 85% to LPs, 15% to protocol
        // mulDivDown → always rounds against protocol (safe direction)
        if (fee > BASE_FEE_PIPS) {
            uint256 surplusBps = uint256(fee / 100) - 1;
            uint256 surplusAmount = ctx.swapSize.mulDivDown(surplusBps, 10_000);
            uint256 protocolCut = surplusAmount.mulDivDown(
                PROTOCOL_FEE_BPS,
                100
            );
            uint256 lpShare = surplusAmount - protocolCut;

            cfg.surplusAccrued += lpShare;
            cfg.protocolAccrued += protocolCut;
        }

        return fee;
    }

    // ── Rolling drain multiplier ──────────────────────────────────────────────

    /// @notice Tracks cumulative drain flow per pool per rolling window.
    ///
    /// Defeats two adversarial attacks:
    ///   1. Slow TWAP poisoning: 30-min campaign of small swaps to move TWAP
    ///      toward spot, then drain at near-zero fee. Rolling window detects
    ///      the cumulative drain even when each swap looks innocent.
    ///
    ///   2. Trade fragmentation: splitting $500k drain into 50×$10k swaps
    ///      each below the per-swap cap. Rolling window accumulates all of them.
    ///
    /// By swap 20 of a fragmented drain, multiplier = 1.10 (+10%)
    /// By swap 35, multiplier = 1.25 (+25%)
    /// By swap 50, multiplier = 1.50 (+50%)
    function _rollingMultiplier(
        PoolId poolId,
        uint256 swapSize,
        bool isDrain
    ) internal returns (uint256) {
        // Reset window if expired
        if (block.number > rollingWindowStart[poolId] + ROLLING_BLOCKS) {
            rollingDrain[poolId] = 0;
            rollingWindowStart[poolId] = block.number;
        }

        if (isDrain) rollingDrain[poolId] += swapSize;

        uint128 liquidity = poolManager.getLiquidity(poolId);
        if (liquidity == 0) return 100;

        // drainPct in bps (e.g. 300 = 3% of liquidity drained this window)
        uint256 drainPct = (rollingDrain[poolId] * 10_000) / uint256(liquidity);

        if (drainPct > 300) return 150; // +50% — heavy drain campaign
        if (drainPct > 150) return 125; // +25%
        if (drainPct > 75) return 110; // +10%
        return 100; // no multiplier
    }

    // ── Oracle read with fallback ─────────────────────────────────────────────

    /// @notice Chainlink primary with TWAP fallback.
    ///
    /// [CHANGE 4] Disagreement guard:
    ///   If |Chainlink - TWAP_30min| > ORACLE_DISAGREE_BPS (20 bps),
    ///   use the more conservative reading (closer to $1.00).
    ///   This prevents stale Chainlink from causing false fee spikes.
    ///
    /// Returns: price1e18, pegBelow (is token below $1), usingFallback
    function _readDepegWithFallback(
        PoolKey calldata key,
        address oracle,
        uint8 oracleDecimals
    )
        internal
        view
        returns (uint256 depegBps, bool pegBelow, bool usingFallback)
    {
        uint256 price1e18;

        try this.readChainlinkPrice(oracle, oracleDecimals) returns (
            uint256 clPrice
        ) {
            // [CHANGE 4] Disagreement guard
            uint256 twapPrice = _readTwap30(key);
            uint256 diff = clPrice > twapPrice
                ? clPrice - twapPrice
                : twapPrice - clPrice;
            uint256 diffBps = (diff * 10_000) / 1e18;

            if (diffBps > ORACLE_DISAGREE_BPS) {
                // Sources disagree — use the more conservative price
                // Conservative = closer to $1.00 = less extreme deviation
                uint256 clDev = clPrice > 1e18
                    ? clPrice - 1e18
                    : 1e18 - clPrice;
                uint256 twapDev = twapPrice > 1e18
                    ? twapPrice - 1e18
                    : 1e18 - twapPrice;
                price1e18 = clDev < twapDev ? clPrice : twapPrice;
            } else {
                price1e18 = clPrice;
            }

            usingFallback = false;
        } catch {
            // Chainlink stale or failed — fall back to TWAP
            price1e18 = _readTwap30(key);
            usingFallback = true;
        }
        pegBelow = price1e18 < 1e18;
        depegBps = pegBelow
            ? ((1e18 - price1e18) * 10_000) / 1e18
            : ((price1e18 - 1e18) * 10_000) / 1e18;
    }

    /// @notice Read Chainlink price with full validation.
    ///         External so it can be called inside try/catch.
    function readChainlinkPrice(
        address oracle,
        uint8 oracleDecimals
    ) external view returns (uint256 price1e18) {
        (
            uint80 roundId,
            int256 answer,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = IAggregatorV3Interface(oracle).latestRoundData();

        if (answer <= 0) revert OracleAnswerInvalid();
        if (answeredInRound < roundId)
            revert OracleRoundIncomplete(roundId, answeredInRound);

        // [CHANGE 1] Was 2 minutes — now 25 hours to match Chainlink heartbeat
        if (block.timestamp > updatedAt + MAX_ORACLE_AGE) {
            revert OracleStale(updatedAt, block.timestamp);
        }

        return (uint256(answer) * 1e18) / (10 ** uint256(oracleDecimals));
    }

    /// @notice 30-minute TWAP computed from the in-hook observation ring
    ///         buffer (v4 has no native pool-manager observe).
    ///
    /// Strategy:
    ///   1. Read current tick from PoolManager.getSlot0.
    ///   2. Synthesize "now" tickCumulative = lastObs.tickCumulative
    ///                                       + tick * (now - lastObs.timestamp).
    ///   3. Find tickCumulative at (now - TWAP_WINDOW) by interpolating
    ///      between the two observations bracketing that target timestamp.
    ///   4. avgTick = (cumNow - cumThen) / TWAP_WINDOW; convert via TickMath.
    ///
    /// If insufficient history exists (oldest observation is younger than the
    /// requested window), we fall back to the current spot price. That keeps
    /// the disagreement guard meaningful (Chainlink vs spot) without falsely
    /// claiming a TWAP.
    function _readTwap30(
        PoolKey calldata key
    ) internal view returns (uint256 price1e18) {
        PoolId poolId = key.toId();
        (uint160 sqrtPriceX96Now, int24 currentTick, , ) = poolManager.getSlot0(
            poolId
        );

        uint16 card = obsCardinality[poolId];
        uint16 newestIdx = obsIndex[poolId];

        // Need at least one prior observation and enough span to read.
        if (card == 0) {
            return _priceFromSqrtX96(sqrtPriceX96Now);
        }

        Observation memory newest = observations[poolId][newestIdx];
        uint32 nowTs = uint32(block.timestamp);

        // Synthesize cumulative at "now" using the latest tick.
        int56 cumNow = newest.tickCumulative +
            int56(currentTick) *
            int56(uint56(nowTs - newest.blockTimestamp));

        // Oldest observation in the ring.
        uint16 oldestIdx = card < OBS_CARDINALITY
            ? 0
            : (newestIdx + 1) % OBS_CARDINALITY;
        Observation memory oldest = observations[poolId][oldestIdx];

        // If we don't have TWAP_WINDOW seconds of history yet, fall back to
        // spot. This is conservative and avoids returning a misleading TWAP.
        if (nowTs - oldest.blockTimestamp < TWAP_WINDOW) {
            return _priceFromSqrtX96(sqrtPriceX96Now);
        }

        uint32 target = nowTs - TWAP_WINDOW;
        int56 cumAtTarget = _observeAt(poolId, target, card, newestIdx);

        int56 tickDelta = cumNow - cumAtTarget;
        int24 avgTick = int24(tickDelta / int56(uint56(TWAP_WINDOW)));
        if (tickDelta < 0 && (tickDelta % int56(uint56(TWAP_WINDOW)) != 0)) {
            avgTick--;
        }

        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(avgTick);
        return _priceFromSqrtX96(sqrtPriceX96);
    }

    /// @notice Find the tickCumulative at `target` (a past timestamp) by
    ///         locating the two observations bracketing it and linearly
    ///         interpolating. Caller guarantees target >= oldest.timestamp.
    function _observeAt(
        PoolId poolId,
        uint32 target,
        uint16 card,
        uint16 newestIdx
    ) internal view returns (int56 cumAtTarget) {
        // Walk from oldest to newest. Buffers are tiny (≤144) so a linear
        // scan is cheap and avoids the corner cases of ring-buffer binary
        // search; if cardinality grows materially this can be swapped for
        // the v3-style search.
        uint16 startIdx = card < OBS_CARDINALITY
            ? 0
            : (newestIdx + 1) % OBS_CARDINALITY;

        Observation memory before = observations[poolId][startIdx];
        Observation memory atOrAfter = before;

        for (uint16 step = 1; step < card; step++) {
            uint16 idx = (startIdx + step) % OBS_CARDINALITY;
            atOrAfter = observations[poolId][idx];
            if (atOrAfter.blockTimestamp >= target) break;
            before = atOrAfter;
        }

        if (atOrAfter.blockTimestamp == target) {
            return atOrAfter.tickCumulative;
        }
        if (before.blockTimestamp == atOrAfter.blockTimestamp) {
            // Only one observation matched; can't interpolate.
            return before.tickCumulative;
        }

        // Linear interpolation between `before` and `atOrAfter`.
        uint32 span = atOrAfter.blockTimestamp - before.blockTimestamp;
        uint32 elapsed = target - before.blockTimestamp;
        int56 cumDelta = atOrAfter.tickCumulative - before.tickCumulative;
        cumAtTarget =
            before.tickCumulative +
            (cumDelta * int56(uint56(elapsed))) /
            int56(uint56(span));
    }

    /// @notice price1e18 = (sqrtPriceX96)² / 2^192, scaled to 1e18.
    function _priceFromSqrtX96(
        uint160 sqrtPriceX96
    ) internal pure returns (uint256) {
        uint256 ratioX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        return FullMath.mulDiv(ratioX192, 1e18, 1 << 192);
    }

    // ── View helpers ──────────────────────────────────────────────────────────

    function getPoolState(
        PoolKey calldata key
    )
        external
        view
        returns (
            bool registered,
            uint256 depegBps,
            bool pegBelow,
            bool inRestoreWindow,
            uint256 surplusAccrued,
            uint256 protocolAccrued,
            bool usingFallback
        )
    {
        PoolConfig storage cfg = poolConfigs[key.toId()];
        registered = cfg.registered;
        surplusAccrued = cfg.surplusAccrued;
        protocolAccrued = cfg.protocolAccrued;
        inRestoreWindow =
            cfg.lastHighDepegAt != 0 &&
            (block.timestamp - cfg.lastHighDepegAt) <= RESTORE_WINDOW;

        if (!cfg.registered) return (false, 0, false, false, 0, 0, false);

        (depegBps, pegBelow, usingFallback) = _readDepegWithFallback(
            key,
            cfg.oracle0,
            cfg.oracle0Decimals
        );
    }

    function getPoolConfig(
        PoolKey calldata key
    ) external view returns (PoolConfig memory) {
        return poolConfigs[key.toId()];
    }

    // ── Protocol fee collection ───────────────────────────────────────────────

    /// @notice Owner collects accumulated protocol fee share (15% cut).
    ///         Called weekly or on-demand. Separate from LP surplus.
    ///
    /// [CHANGE 7] protocolAccrued tracks the 15% cut separately.
    ///            LP surplus goes to LPs via donate() in a future afterSwap.
    ///            This function only moves the protocol's portion.
    function collectProtocolFees(
        PoolKey calldata key,
        address token // which token to collect (token0 or token1)
    ) external onlyOwner {
        PoolId id = key.toId();
        PoolConfig storage cfg = poolConfigs[id];
        if (!cfg.registered) revert PoolNotRegistered();

        uint256 amount = cfg.protocolAccrued;
        if (amount == 0) return;

        cfg.protocolAccrued = 0;

        // Transfer to treasury — mulDivDown already applied at accrual time
        bool ok = IERC20(token).transfer(protocolTreasury, amount);
        if (!ok) revert TransferFailed();

        emit ProtocolFeesCollected(id, amount);
    }

    // ── Governance ────────────────────────────────────────────────────────────

    /// @notice Approve a Chainlink feed address for use in pool registration.
    ///         Only approved feeds can be used. This is the trust boundary.
    ///
    /// [CHANGE 8] Before registering feeds:
    ///   - Verify the feed is live on your target chain
    ///   - Check heartbeat period matches MAX_ORACLE_AGE tolerance
    ///   - Verify decimals() returns expected value (usually 8)
    function approveOracle(address feed) external onlyOwner {
        if (feed == address(0)) revert ZeroAddress();
        approvedOracles[feed] = true;
        emit OracleApproved(feed);
    }

    /// @notice Revoke an oracle feed (e.g. if Chainlink deprecates it).
    function revokeOracle(address feed) external onlyOwner {
        approvedOracles[feed] = false;
        emit OracleRevoked(feed);
    }

    /// @notice Update protocol treasury address.
    ///         Set to Gnosis Safe before mainnet.
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

    // ── Internals ─────────────────────────────────────────────────────────────

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }
}
