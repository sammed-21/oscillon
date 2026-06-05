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

    function readTwapOrSpot(IPoolManager poolManager, PoolKey calldata key, TwapState storage state)
        internal
        view
        returns (uint256 price1e18)
    {
        PoolId poolId = key.toId();
        (uint160 sqrtPriceX96Now, int24 currentTick, , ) = poolManager.getSlot0(poolId);

        uint16 card = state.obsCardinality;
        uint16 newestIdx = state.obsIndex;

        if (card == 0) return priceFromSqrtX96(sqrtPriceX96Now);

        Observation memory newest = state.observations[newestIdx];
        uint32 nowTs = uint32(block.timestamp);

        int56 cumNow = newest.tickCumulative
            + int56(currentTick) * int56(uint56(nowTs - newest.blockTimestamp));

        uint16 oldestIdx = card < C.OBS_CARDINALITY ? 0 : (newestIdx + 1) % C.OBS_CARDINALITY;
        Observation memory oldest = state.observations[oldestIdx];

        if (nowTs - oldest.blockTimestamp < C.TWAP_WINDOW) {
            return priceFromSqrtX96(sqrtPriceX96Now);
        }

        uint32 target = nowTs - C.TWAP_WINDOW;
        int56 cumAtTarget = observeAt(state, target, card, newestIdx);

        int56 tickDelta = cumNow - cumAtTarget;
        int24 avgTick = int24(tickDelta / int56(uint56(C.TWAP_WINDOW)));
        if (tickDelta < 0 && (tickDelta % int56(uint56(C.TWAP_WINDOW)) != 0)) {
            avgTick--;
        }

        return priceFromSqrtX96(TickMath.getSqrtPriceAtTick(avgTick));
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

    function priceFromSqrtX96(uint160 sqrtPriceX96) internal pure returns (uint256) {
        uint256 ratioX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        return FullMath.mulDiv(ratioX192, 1e18, 1 << 192);
    }
}
