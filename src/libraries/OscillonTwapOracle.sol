// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Observation, TwapState} from "../types/OscillonTypes.sol";
import {OscillonConstants as C} from "../constants/OscillonConstants.sol";

library OscillonTwapOracle {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function seed(TwapState storage state) internal {
        state.observations[0] = Observation({
            blockTimestamp: uint32(block.timestamp),
            tickCumulative: 0,
            initialized: true
        });
        state.obsIndex = 0;
        state.obsCardinality = 1;
    }

    function write(TwapState storage state, int24 currentTick) internal {
        uint16 lastIdx = state.obsIndex;
        Observation memory last = state.observations[lastIdx];

        if (!last.initialized) {
            seed(state);
            return;
        }

        uint32 nowTs = uint32(block.timestamp);
        if (nowTs == last.blockTimestamp) return;

        int56 delta = int56(uint56(nowTs - last.blockTimestamp));
        int56 newCumulative = last.tickCumulative + int56(currentTick) * delta;

        uint16 nextIdx = (lastIdx + 1) % C.OBS_CARDINALITY;
        state.observations[nextIdx] = Observation({
            blockTimestamp: nowTs,
            tickCumulative: newCumulative,
            initialized: true
        });
        state.obsIndex = nextIdx;

        uint16 card = state.obsCardinality;
        if (card < C.OBS_CARDINALITY) state.obsCardinality = card + 1;
    }

    /// @return price1e18 the TWAP price, or raw spot if the ring buffer
    ///         hasn't accumulated a full TWAP_WINDOW of history yet.
    /// @return warmedUp true only when `price1e18` is a real windowed
    ///         average — false whenever it's actually raw spot (freshly
    ///         registered pool, or fewer than TWAP_WINDOW seconds of
    ///         observations so far). Reporting-only: does not change fee
    ///         behavior on its own; callers decide what to do with it.
    /// @param decimals0 decimals of currency0, decimals1 of currency1 — v4's
    ///        sqrtPriceX96 encodes a raw currency1-per-currency0 unit ratio,
    ///        not a dollar-comparable price; for equal-decimal pairs (e.g.
    ///        USDC/USDT, both 6) the raw ratio already IS the dollar price,
    ///        but for a real gap (e.g. USDe 18 vs USDC 6) it's off by
    ///        10^|decimals0-decimals1| unless corrected here.
    function readTwapOrSpot(
        IPoolManager poolManager,
        PoolKey calldata key,
        TwapState storage state,
        uint8 decimals0,
        uint8 decimals1
    ) internal view returns (uint256 price1e18, bool warmedUp) {
        PoolId poolId = key.toId();
        (uint160 sqrtPriceX96Now, int24 currentTick, , ) = poolManager.getSlot0(poolId);

        uint16 card = state.obsCardinality;
        uint16 newestIdx = state.obsIndex;

        // card == 1 means only the synthetic seed observation exists (written
        // at init with tickCumulative == 0 regardless of the pool's actual
        // starting tick) — no real trading history to average over yet. Time
        // alone isn't enough to call this "warmed up": extrapolating from
        // that single zero-cumulative point across however long it's been
        // since init, using whatever the tick happens to be *now*, produces
        // a wild (and, for a tick far from 0, out-of-range) fake average.
        // Every pool before this one initialized near tick 0, where that
        // extrapolation error was invisible (0 * anything == 0).
        if (card < 2) {
            return (priceFromSqrtX96(sqrtPriceX96Now, decimals0, decimals1), false);
        }

        uint32 nowTs = uint32(block.timestamp);
        uint16 oldestIdx = card < C.OBS_CARDINALITY ? 0 : (newestIdx + 1) % C.OBS_CARDINALITY;
        Observation memory oldest = state.observations[oldestIdx];

        if (nowTs - oldest.blockTimestamp < C.TWAP_WINDOW) {
            return (priceFromSqrtX96(sqrtPriceX96Now, decimals0, decimals1), false);
        }

        int24 avgTick = _computeAvgTick(state, card, newestIdx, currentTick, nowTs);
        return (
            priceFromSqrtX96(TickMath.getSqrtPriceAtTick(avgTick), decimals0, decimals1),
            true
        );
    }

    /// @dev Split out of readTwapOrSpot purely to keep that function's stack
    ///      depth under the legacy codegen limit — adding decimals0/decimals1
    ///      there pushed it over.
    function _computeAvgTick(
        TwapState storage state,
        uint16 card,
        uint16 newestIdx,
        int24 currentTick,
        uint32 nowTs
    ) private view returns (int24 avgTick) {
        Observation memory newest = state.observations[newestIdx];
        int56 cumNow = newest.tickCumulative
            + int56(currentTick) * int56(uint56(nowTs - newest.blockTimestamp));

        uint32 target = nowTs - C.TWAP_WINDOW;
        int56 cumAtTarget = observeAt(state, target, card, newestIdx);

        int56 tickDelta = cumNow - cumAtTarget;
        avgTick = int24(tickDelta / int56(uint56(C.TWAP_WINDOW)));
        if (tickDelta < 0 && (tickDelta % int56(uint56(C.TWAP_WINDOW)) != 0)) {
            avgTick--;
        }
    }

    function observeAt(TwapState storage state, uint32 target, uint16 card, uint16 newestIdx)
        internal
        view
        returns (int56 cumAtTarget)
    {
        uint16 startIdx = card < C.OBS_CARDINALITY ? 0 : (newestIdx + 1) % C.OBS_CARDINALITY;

        Observation memory before = state.observations[startIdx];
        Observation memory atOrAfter = before;

        for (uint16 step = 1; step < card; step++) {
            uint16 idx = (startIdx + step) % C.OBS_CARDINALITY;
            atOrAfter = state.observations[idx];
            if (atOrAfter.blockTimestamp >= target) break;
            before = atOrAfter;
        }

        if (atOrAfter.blockTimestamp == target) return atOrAfter.tickCumulative;
        if (before.blockTimestamp == atOrAfter.blockTimestamp) return before.tickCumulative;

        uint32 span = atOrAfter.blockTimestamp - before.blockTimestamp;
        uint32 elapsed = target - before.blockTimestamp;
        int56 cumDelta = atOrAfter.tickCumulative - before.tickCumulative;
        cumAtTarget = before.tickCumulative + (cumDelta * int56(uint56(elapsed))) / int56(uint56(span));
    }

    /// @dev sqrtPriceX96 encodes a raw currency1-per-currency0 unit ratio.
    ///      Scaling by 10^(decimals0-decimals1) converts that into a
    ///      dollar-comparable price when both tokens are ~$1 stables — a
    ///      no-op when decimals0 == decimals1 (e.g. USDC/USDT, both 6).
    function priceFromSqrtX96(
        uint160 sqrtPriceX96,
        uint8 decimals0,
        uint8 decimals1
    ) internal pure returns (uint256) {
        uint256 ratioX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        uint256 rawPrice1e18 = FullMath.mulDiv(ratioX192, 1e18, 1 << 192);

        if (decimals0 == decimals1) return rawPrice1e18;
        if (decimals0 > decimals1) {
            return rawPrice1e18 * (10 ** uint256(decimals0 - decimals1));
        }
        return rawPrice1e18 / (10 ** uint256(decimals1 - decimals0));
    }
}
