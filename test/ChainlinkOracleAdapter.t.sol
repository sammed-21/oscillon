// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {MockV3Aggregator} from "./mock/MockV3Aggregator.sol";
import {ChainlinkOracleAdapter} from "../src/oracle/adapters/ChainlinkOracleAdapter.sol";
import {OracleAnswerAtBound} from "../src/errors/OscillonErrors.sol";
import {OscillonConstants as C} from "../src/constants/OscillonConstants.sol";

/// @notice Unit tests for the minAnswer/maxAnswer circuit breaker
///         (LUNA/UST-style floor defense) in isolation from the hook.
contract ChainlinkOracleAdapterTest is Test {
    MockV3Aggregator oracle;
    ChainlinkOracleAdapter adapter;

    function setUp() public {
        oracle = new MockV3Aggregator(18, int256(1e18));
        adapter = new ChainlinkOracleAdapter(
            address(oracle),
            address(0),
            C.MAX_ORACLE_AGE
        );
    }

    function test_boundsUnknown_byDefault_widePlaceholderBounds() public view {
        // MockV3Aggregator defaults to (near) the full int192 range, so a
        // normal $1 answer never trips the breaker.
        assertTrue(adapter.boundsKnown());
        (uint256 price, ) = adapter.getPrice();
        assertEq(price, 1e18);
    }

    function test_answerAtMinBound_reverts() public {
        // Aggregator configured with a $0.10 floor; price is currently
        // pinned exactly at that floor — this is the saturation scenario,
        // not a legitimate $0.10 market price.
        // Bounds are immutable, cached at construction (mirrors real
        // Chainlink: an aggregator's min/max are fixed for its lifetime —
        // Chainlink deploys a NEW aggregator behind the proxy to change
        // them), so the mock must be configured before the adapter exists.
        oracle = new MockV3Aggregator(18, int256(0.10e18));
        oracle.setAnswerBounds(int192(0.10e18), type(int192).max);
        adapter = new ChainlinkOracleAdapter(
            address(oracle),
            address(0),
            C.MAX_ORACLE_AGE
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                OracleAnswerAtBound.selector,
                int256(0.10e18),
                int256(0.10e18),
                int256(int192(type(int192).max))
            )
        );
        adapter.getPrice();
    }

    function test_answerBelowMinBound_reverts() public {
        oracle = new MockV3Aggregator(18, int256(0.05e18));
        oracle.setAnswerBounds(int192(0.10e18), type(int192).max);
        adapter = new ChainlinkOracleAdapter(
            address(oracle),
            address(0),
            C.MAX_ORACLE_AGE
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                OracleAnswerAtBound.selector,
                int256(0.05e18),
                int256(0.10e18),
                int256(int192(type(int192).max))
            )
        );
        adapter.getPrice();
    }

    function test_answerAtMaxBound_reverts() public {
        oracle = new MockV3Aggregator(18, int256(10e18));
        oracle.setAnswerBounds(type(int192).min, int192(10e18));
        adapter = new ChainlinkOracleAdapter(
            address(oracle),
            address(0),
            C.MAX_ORACLE_AGE
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                OracleAnswerAtBound.selector,
                int256(10e18),
                int256(int192(type(int192).min)),
                int256(10e18)
            )
        );
        adapter.getPrice();
    }

    function test_answerStrictlyBetweenBounds_succeeds() public {
        oracle = new MockV3Aggregator(18, int256(1e18));
        oracle.setAnswerBounds(int192(0.10e18), int192(10e18));
        adapter = new ChainlinkOracleAdapter(
            address(oracle),
            address(0),
            C.MAX_ORACLE_AGE
        );

        (uint256 price, ) = adapter.getPrice();
        assertEq(price, 1e18);
    }

    function test_isHealthy_falseWhenAtBound() public {
        oracle = new MockV3Aggregator(18, int256(0.10e18));
        oracle.setAnswerBounds(int192(0.10e18), type(int192).max);
        adapter = new ChainlinkOracleAdapter(
            address(oracle),
            address(0),
            C.MAX_ORACLE_AGE
        );

        assertFalse(adapter.isHealthy());
    }
}
