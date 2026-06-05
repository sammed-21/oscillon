// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {OscillonConstants as C} from "../constants/OscillonConstants.sol";

library OscillonDepegMath {
    function depegFromPrice(uint256 price1e18) internal pure returns (uint256 depegBps, bool pegBelow) {
        pegBelow = price1e18 < 1e18;
        depegBps = pegBelow
            ? ((1e18 - price1e18) * 10_000) / 1e18
            : ((price1e18 - 1e18) * 10_000) / 1e18;
    }

    function deviationFromPeg(uint256 price1e18) internal pure returns (uint256) {
        return price1e18 > 1e18 ? price1e18 - 1e18 : 1e18 - price1e18;
    }

    function diffBps(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 diff = a > b ? a - b : b - a;
        return (diff * 10_000) / 1e18;
    }

    /// @notice When sources disagree, pick the price closer to $1.00 (conservative).
    function conservativePrice(uint256 priceA, uint256 priceB) internal pure returns (uint256) {
        uint256 devA = deviationFromPeg(priceA);
        uint256 devB = deviationFromPeg(priceB);
        return devA < devB ? priceA : priceB;
    }

    function pricesDisagree(uint256 priceA, uint256 priceB) internal pure returns (bool) {
        return diffBps(priceA, priceB) > C.ORACLE_DISAGREE_BPS;
    }
}
