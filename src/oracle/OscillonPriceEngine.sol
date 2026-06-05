// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IOscillonOracle} from "./IOscillonOracle.sol";
import {TokenOracleConfig, PriceResult} from "../types/OscillonTypes.sol";
import {OscillonDepegMath} from "../libraries/OscillonDepegMath.sol";

/// @title OscillonPriceEngine
/// @notice Chainlink primary with in-pool TWAP fallback and disagreement guard.
/// @dev Phase 1: Chainlink + TWAP. New IOscillonOracle adapters can extend the cascade later.
library OscillonPriceEngine {
    uint8 internal constant SOURCE_CHAINLINK = 1;
    uint8 internal constant SOURCE_TWAP = 2;

    function getSellTokenPrice(TokenOracleConfig memory cfg, uint256 twapPrice1e18)
        internal
        view
        returns (PriceResult memory result)
    {
        if (cfg.chainlinkAdapter != address(0)) {
            (bool ok, PriceResult memory fromCl) = _tryChainlink(cfg.chainlinkAdapter, twapPrice1e18);
            if (ok) return fromCl;
        }

        return _fromTwap(twapPrice1e18);
    }

    function _tryChainlink(address chainlinkAdapter, uint256 twapPrice1e18)
        internal
        view
        returns (bool ok, PriceResult memory result)
    {
        try IOscillonOracle(chainlinkAdapter).getPrice() returns (uint256 clPrice, uint256) {
            uint256 finalPrice = OscillonDepegMath.pricesDisagree(clPrice, twapPrice1e18)
                ? OscillonDepegMath.conservativePrice(clPrice, twapPrice1e18)
                : clPrice;

            uint8 source = finalPrice == twapPrice1e18 && finalPrice != clPrice
                ? SOURCE_TWAP
                : SOURCE_CHAINLINK;

            return (true, _pack(finalPrice, source, false));
        } catch {
            return (false, result);
        }
    }

    function _fromTwap(uint256 twapPrice1e18) internal pure returns (PriceResult memory result) {
        return _pack(twapPrice1e18, SOURCE_TWAP, true);
    }

    function _pack(uint256 price1e18, uint8 source, bool usingFallback)
        internal
        pure
        returns (PriceResult memory result)
    {
        (uint256 depegBps, bool pegBelow) = OscillonDepegMath.depegFromPrice(price1e18);
        result = PriceResult({
            price1e18: price1e18,
            depegBps: depegBps,
            pegBelow: pegBelow,
            usingFallback: usingFallback,
            source: source
        });
    }
}
