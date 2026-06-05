// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {OscillonConstants as C} from "../constants/OscillonConstants.sol";

/// @title OscillonFeePolicy
/// @notice Hybrid piecewise + quadratic drain fee model (returns bps, hook converts to pips).
library OscillonFeePolicy {
    function kForLiquidity(uint128 poolLiquidity) internal pure returns (uint256) {
        return uint256(poolLiquidity) < C.THIN_POOL_LIQUIDITY ? C.K_THIN : C.K_STANDARD;
    }

    function hybridFeeBps(uint256 devBps, uint256 k) internal pure returns (uint256) {
        if (devBps == 0) return 1;

        uint256 pw = piecewiseFeeBps(devBps);

        uint256 d = devBps > C.QUADRATIC_DEAD_BAND ? devBps - C.QUADRATIC_DEAD_BAND : 0;
        uint256 quad = 1 + (k * d * d) / 10_000;
        if (quad > C.MAX_FEE_BPS) quad = C.MAX_FEE_BPS;

        return pw > quad ? pw : quad;
    }

    function piecewiseFeeBps(uint256 devBps) internal pure returns (uint256) {
        if (devBps <= C.QUADRATIC_DEAD_BAND) return 1;

        if (devBps <= 20) {
            uint256 excess = devBps - C.QUADRATIC_DEAD_BAND;
            uint256 feeX10000 = 10_000 + 204 * excess * excess;
            return feeX10000 / 10_000;
        }

        uint256 feeAt20X10000 = 10_000 + 204 * 17 * 17;
        uint256 linearX10000 = 11 * (devBps - 20) * 100;
        uint256 totalX10000 = feeAt20X10000 + linearX10000;
        uint256 feeBps = totalX10000 / 10_000;
        return feeBps > C.MAX_FEE_BPS ? C.MAX_FEE_BPS : feeBps;
    }

    /// @notice Apply TWAP-fallback dampening then rolling multiplier; input/output in pips.
    function applyDrainAdjustments(
        uint256 feeBps,
        bool usingFallback,
        uint256 depegBps,
        uint256 rollingMult
    ) internal pure returns (uint24 feePips) {
        uint256 adjusted = feeBps;

        if (usingFallback && depegBps < 15) {
            uint256 increase = adjusted > 1 ? adjusted - 1 : 0;
            adjusted = 1 + (increase / 2);
        }

        adjusted = (adjusted * rollingMult) / 100;
        uint256 pips = adjusted * 100;
        feePips = uint24(pips > C.MAX_FEE_PIPS ? C.MAX_FEE_PIPS : pips);
    }

    function rollingMultiplier(uint256 drainPctBps) internal pure returns (uint256) {
        if (drainPctBps > 300) return 150;
        if (drainPctBps > 150) return 125;
        if (drainPctBps > 75) return 110;
        return 100;
    }
}
