// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IOscillonOracle} from "../IOscillonOracle.sol";
import {IChainlinkSequencer} from "../IChainlinkSequencer.sol";
import {IChainlinkAggregator, IChainlinkAggregatorProxy} from "../IChainlinkAggregator.sol";
import {IAggregatorV3Interface} from "../../interface/IAggregatorV3Interface.sol";
import {OracleAnswerInvalid, OracleStale, OracleRoundIncomplete, OracleAnswerAtBound, SequencerDown} from "../../errors/OscillonErrors.sol";
import {OscillonConstants as C} from "../../constants/OscillonConstants.sol";

/// @title ChainlinkOracleAdapter
/// @notice IOscillonOracle wrapper for Chainlink USD feeds with optional L2 sequencer check.
contract ChainlinkOracleAdapter is IOscillonOracle {
    IAggregatorV3Interface public immutable feed;
    IChainlinkSequencer public immutable sequencer;
    uint8 public immutable feedDecimals;
    uint256 public immutable maxAge;

    /// @notice minAnswer/maxAnswer circuit breaker (LUNA/UST-style floor
    ///         defense): if the underlying aggregator behind `feed` is
    ///         clamped at its configured answer bound, the reading is not a
    ///         real market price — it's the aggregator's saturation value.
    ///         Resolved once at construction from `feed` (or the aggregator
    ///         it proxies to); if neither exposes bounds, the check is
    ///         skipped rather than failing closed on every read. A feed
    ///         migration to a new underlying aggregator requires deploying a
    ///         new adapter, same as any other feed-config change here.
    bool public immutable boundsKnown;
    int256 public immutable minAnswerBound;
    int256 public immutable maxAnswerBound;

    constructor(address _feed, address _sequencer, uint256 _maxAge) {
        feed = IAggregatorV3Interface(_feed);
        sequencer = IChainlinkSequencer(_sequencer);
        feedDecimals = feed.decimals();
        maxAge = _maxAge == 0 ? C.MAX_ORACLE_AGE : _maxAge;

        (bool known, int256 minB, int256 maxB) = _tryFetchBounds(_feed);
        boundsKnown = known;
        minAnswerBound = minB;
        maxAnswerBound = maxB;
    }

    function _tryFetchBounds(
        address _feed
    ) private view returns (bool known, int256 minB, int256 maxB) {
        address aggregatorAddr = _feed;
        try IChainlinkAggregatorProxy(_feed).aggregator() returns (
            address underlying
        ) {
            aggregatorAddr = underlying;
        } catch {
            // `_feed` is not a proxy (or doesn't expose aggregator()) —
            // fall back to treating it as the aggregator itself.
        }

        try IChainlinkAggregator(aggregatorAddr).minAnswer() returns (
            int192 minAns
        ) {
            try IChainlinkAggregator(aggregatorAddr).maxAnswer() returns (
                int192 maxAns
            ) {
                return (true, int256(minAns), int256(maxAns));
            } catch {
                return (false, 0, 0);
            }
        } catch {
            return (false, 0, 0);
        }
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

        // Chainlink aggregators saturate at a configured min/max instead of
        // reverting when the real price moves past their bound — this is
        // exactly what happened to LUNA/UST feeds in May 2022, where the
        // aggregator kept reporting minAnswer long after the real price fell
        // further. A clamped reading isn't a stale reading (updatedAt keeps
        // advancing), so the staleness check above can't catch it; reverting
        // here routes through the same try/catch in OscillonPriceEngine that
        // staleness uses, falling through to the TWAP fallback instead of
        // pricing swaps off a saturated floor/ceiling.
        if (
            boundsKnown &&
            (answer <= minAnswerBound || answer >= maxAnswerBound)
        ) {
            revert OracleAnswerAtBound(answer, minAnswerBound, maxAnswerBound);
        }

        return (uint256(answer) * 1e18) / (10 ** uint256(feedDecimals));
    }
}
