// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IOscillonOracle} from "../IOscillonOracle.sol";
import {IChainlinkSequencer} from "../IChainlinkSequencer.sol";
import {
    IAggregatorV3Interface
} from "../../interface/IAggregatorV3Interface.sol";
import {
    OracleAnswerInvalid,
    OracleStale,
    OracleRoundIncomplete,
    SequencerDown
} from "../../errors/OscillonErrors.sol";
import {OscillonConstants as C} from "../../constants/OscillonConstants.sol";

/// @title ChainlinkOracleAdapter
/// @notice IOscillonOracle wrapper for Chainlink USD feeds with optional L2 sequencer check.
contract ChainlinkOracleAdapter is IOscillonOracle {
    IAggregatorV3Interface public immutable feed;
    IChainlinkSequencer public immutable sequencer;
    uint8 public immutable feedDecimals;
    uint256 public immutable maxAge;

    constructor(address _feed, address _sequencer, uint256 _maxAge) {
        feed = IAggregatorV3Interface(_feed);
        sequencer = IChainlinkSequencer(_sequencer);
        feedDecimals = feed.decimals();
        maxAge = _maxAge == 0 ? C.MAX_ORACLE_AGE : _maxAge;
    }

    function getPrice()
        external
        view
        override
        returns (uint256 price1e18, uint256 confidence)
    {
        _assertSequencerUp();
        price1e18 = _readFeed();
        confidence = 0;
    }

    function isHealthy() external view override returns (bool) {
        try this.getPrice() returns (uint256, uint256) {
            return true;
        } catch {
            return false;
        }
    }

    function _assertSequencerUp() internal view {
        if (address(sequencer) == address(0)) return;

        (, int256 seqAnswer, uint256 startedAt, , ) = sequencer
            .latestRoundData();
        if (seqAnswer == 1) revert SequencerDown();
        if (block.timestamp - startedAt < C.SEQUENCER_GRACE_PERIOD)
            revert SequencerDown();
    }

    function _readFeed() internal view returns (uint256 price1e18) {
        (
            uint80 roundId,
            int256 answer,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = feed.latestRoundData();

        if (answer <= 0) revert OracleAnswerInvalid();
        if (answeredInRound < roundId)
            revert OracleRoundIncomplete(roundId, answeredInRound);
        if (block.timestamp > updatedAt + maxAge)
            revert OracleStale(updatedAt, block.timestamp);

        return (uint256(answer) * 1e18) / (10 ** uint256(feedDecimals));
    }
}
