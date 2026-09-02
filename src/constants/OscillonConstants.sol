// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

library OscillonConstants {
    // Fee (pips = hundredths of a bip; 100 pips = 1 bps)
    uint24 internal constant BASE_FEE_PIPS = 300;
    uint24 internal constant RESTORE_FEE_PIPS = 300;
    uint24 internal constant MAX_FEE_PIPS = 5000;
    uint24 internal constant MAX_FEE_BPS = 50;

    // Depeg gates
    uint256 internal constant SMALL_DEPEG_BPS = 3;
    uint256 internal constant QUADRATIC_DEAD_BAND = 3;
    // Below this, the per-swap drain cap doesn't apply at all — mild
    // deviations (3-14 bps) are priced via the surcharge, not size-limited,
    // so routine volume isn't blocked. At/above it, the cap is the hard
    // per-transaction ceiling regardless of trader capital.
    uint256 internal constant CAP_DEPEG_BPS = 15;

    // Timing — MAX_ORACLE_AGE aligned with fee-curve horizon (3–50 bps depegs are
    // intraday events; stale Chainlink must not price drain swaps for hours).
    uint256 internal constant RESTORE_WINDOW = 1 hours;
    uint256 internal constant MAX_ORACLE_AGE = 1 hours;
    uint256 internal constant ORACLE_DISAGREE_BPS = 20;
    uint256 internal constant SEQUENCER_GRACE_PERIOD = 3600;

    // Swap caps / rolling window
    uint256 internal constant MAX_DEPEG_SWAP_FACTOR = 500_000;
    uint32 internal constant ROLLING_BLOCKS = 300;

    // TWAP
    uint16 internal constant OBS_CARDINALITY = 144;
    uint32 internal constant TWAP_WINDOW = 1800;

    // Revenue split
    uint256 internal constant PROTOCOL_FEE_BPS = 15;
    uint256 internal constant LP_FEE_BPS = 85;

    // Liquidity tier for K selection
    // uint256 internal constant THIN_POOL_LIQUIDITY = 500_000e6;
    uint256 internal constant K_THIN = 60;
    uint256 internal constant K_STANDARD = 45;
}
