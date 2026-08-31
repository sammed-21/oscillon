// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Underlying Chainlink aggregator (behind an EACAggregatorProxy) that
///         exposes the answer floor/ceiling it was deployed with.
interface IChainlinkAggregator {
    function minAnswer() external view returns (int192);
    function maxAnswer() external view returns (int192);
}

/// @notice Most Chainlink feed addresses handed to consumers are proxies;
///         `aggregator()` resolves to the underlying contract that actually
///         holds minAnswer/maxAnswer.
interface IChainlinkAggregatorProxy {
    function aggregator() external view returns (address);
}
