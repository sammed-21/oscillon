// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice Per-token oracle config. TWAP fallback is always pool-level in the hook.
/// @dev Additional providers (e.g. Pyth) plug in via IOscillonOracle + PriceEngine updates.
struct TokenOracleConfig {
    address chainlinkAdapter;
}

struct PoolConfig {
    bool registered;
    address token0;
    address token1;
    TokenOracleConfig oracles0;
    TokenOracleConfig oracles1;
    uint256 maxDepegSwap0;
    uint256 maxDepegSwap1;
    uint256 lastHighDepegAt;
    uint256 surplusAccrued;
    uint256 protocolAccrued;
}

struct Observation {
    uint32 blockTimestamp;
    int56 tickCumulative;
    bool initialized;
}

struct TwapState {
    mapping(uint16 => Observation) observations;
    uint16 obsIndex;
    uint16 obsCardinality;
}

struct SwapContext {
    uint256 depegBps;
    bool isDrain;
    bool usingFallback;
    uint8 priceSource;
    int256 amountSpecified;
    uint256 swapSize;
    bool tokenInIsToken0;
}

/// @notice Oracle source for the final price (1=Chainlink, 2=TWAP)
struct PriceResult {
    uint256 price1e18;
    uint256 depegBps;
    bool pegBelow;
    bool usingFallback;
    uint8 source;
}
