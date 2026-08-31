// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title MockV3Aggregator
/// @notice Mock Chainlink V3-style aggregator for tests. Compatible with IChainlinkOracle (latestRoundData).
contract MockV3Aggregator {
    uint8 private _decimals;
    int256 private _answer;
    uint256 private _updatedAt;

    // minAnswer/maxAnswer circuit breaker support. Defaults to (almost) the
    // full int192 range so existing tests are unaffected unless a test
    // explicitly narrows the bounds. Mock acts as its own "aggregator" (no
    // proxy indirection) — ChainlinkOracleAdapter's aggregator() lookup will
    // revert against this contract and fall back to querying it directly,
    // same as a real non-proxied aggregator.
    int192 private _minAnswer = type(int192).min;
    int192 private _maxAnswer = type(int192).max;

    constructor(uint8 decimals_, int256 answer_) {
        _decimals = decimals_;
        _answer = answer_;
        _updatedAt = block.timestamp;
    }

    function minAnswer() external view returns (int192) {
        return _minAnswer;
    }

    function maxAnswer() external view returns (int192) {
        return _maxAnswer;
    }

    /// @notice For testing the minAnswer/maxAnswer circuit breaker.
    function setAnswerBounds(int192 min_, int192 max_) external {
        _minAnswer = min_;
        _maxAnswer = max_;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    /// @dev Returns (roundId, answer, startedAt, updatedAt, answeredInRound). updatedAt = block.timestamp so OscillonHook's staleness check passes.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (0, _answer, _updatedAt, _updatedAt, 0);
    }

    /// @notice For tests that need to change oracle price (e.g. depeg scenarios)
    function updateAnswer(int256 answer_) external {
        _answer = answer_;
        _updatedAt = block.timestamp;
    }

    /// @notice For testing stale-oracle behavior.
    function setUpdatedAt(uint256 updatedAt_) external {
        _updatedAt = updatedAt_;
    }
}
