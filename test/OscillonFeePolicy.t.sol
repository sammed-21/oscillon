// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {OscillonFeePolicy} from "../src/libraries/OscillonFeePolicy.sol";

contract OscillonFeePolicyTest is Test {
    function test_hybridFee_at20Bps_usesPiecewise() public pure {
        uint256 fee = OscillonFeePolicy.hybridFeeBps(20, 45);
        assertEq(fee, 6);
    }

    function test_hybridFee_zeroDev_returnsOneBps() public pure {
        assertEq(OscillonFeePolicy.hybridFeeBps(0, 45), 1);
    }

    function test_piecewise_zone1_deadBand() public pure {
        assertEq(OscillonFeePolicy.piecewiseFeeBps(3), 1);
        assertEq(OscillonFeePolicy.piecewiseFeeBps(2), 1);
    }

    function test_piecewise_cappedAt50() public pure {
        assertEq(OscillonFeePolicy.piecewiseFeeBps(10_000), 50);
    }

    function test_depegSurcharge_noFallbackDampening() public pure {
        uint24 withFallback =
            OscillonFeePolicy.depegSurchargePips(3, true, 6, 100);
        uint24 withoutFallback =
            OscillonFeePolicy.depegSurchargePips(3, false, 6, 100);
        assertEq(withFallback, withoutFallback);
        assertEq(withFallback, 300);
    }
}
