// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IOscillonOracle
/// @notice Common adapter interface for all price sources (Chainlink today; Pyth/others later).
interface IOscillonOracle {
    /// @return price1e18  e.g. $0.9993 = 999300000000000000
    /// @return confidence  Uncertainty in bps (0 = fully trusted / unavailable)
    function getPrice() external view returns (uint256 price1e18, uint256 confidence);

    /// @return true when the source can return a valid price right now
    function isHealthy() external view returns (bool);
}
