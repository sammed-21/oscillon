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

    // Timing
    uint256 internal constant RESTORE_WINDOW = 1 hours;

    // MAX_ORACLE_AGE mirrors the feed's own heartbeat, not an arbitrary
    // tight window. Chainlink only pushes a new round when either the
    // heartbeat interval elapses or price moves past the deviation
    // threshold, so a healthy USDC/USDT-class feed (heartbeat ~24h) can
    // legitimately stay silent for a comparable stretch on a flat day —
    // that silence is the feed doing its job, not staleness. A window
    // tighter than the feed's real cadence (the old flat 1h) misclassified
    // that entire healthy stretch as "stale" and routed swaps to the TWAP
    // fallback for no real reason. This default assumes a USDC-class feed;
    // a pool on a feed with a different heartbeat should pass its own
    // heartbeat-derived maxAge at adapter construction (see RS_MAX_AGE in
    // the deploy script for the RedStone precedent).
    //
    // This is a trust window, not a bypass: an answer inside this age is
    // used as-is regardless of its value (see ChainlinkOracleAdapter and
    // OscillonHook's no-usable-Chainlink branch). There is deliberately no
    // separate "in-band therefore ignore age" shortcut anywhere in the
    // cascade — a feed frozen near $1 for longer than its own heartbeat is
    // exactly the failure this age check exists to catch, and must still
    // be treated as unusable once it crosses maxAge, no matter how
    // reasonable its frozen value looks.
    uint256 internal constant CHAINLINK_HEARTBEAT_USDC = 24 hours;
    uint256 internal constant ORACLE_AGE_BUFFER = 1 hours;
    uint256 internal constant MAX_ORACLE_AGE =
        CHAINLINK_HEARTBEAT_USDC + ORACLE_AGE_BUFFER; // 25h

    uint256 internal constant ORACLE_DISAGREE_BPS = 20;
    uint256 internal constant SEQUENCER_GRACE_PERIOD = 3600;

    // Swap caps / rolling window
    uint256 internal constant MAX_DEPEG_SWAP_FACTOR = 500_000;
    uint32 internal constant ROLLING_BLOCKS = 300;

    // TWAP
    uint16 internal constant OBS_CARDINALITY = 144;
    uint32 internal constant TWAP_WINDOW = 1800;

    // TWAP trust gating — a windowed average with too few real observations
    // can be dominated by a single trade; a wide TWAP_WINDOW alone doesn't
    // prevent that. MIN_TWAP_OBSERVATIONS requires real trading history
    // beyond just "past the seed." MIN_NEARBY_DEPTH_BPS requires the token
    // depth sitting within TRUST_CHECK_TICK_BAND of the current price to be
    // at least this fraction of the pool's own registered max-drain-size —
    // if a single max-sized swap could dominate the nearby liquidity, this
    // pool's TWAP is cheap to walk.
    //
    // NOT currently wired into the fee/cap decision: OscillonHook no longer
    // ever prices a swap off the TWAP-as-USD when Chainlink has no usable
    // print, trusted or not (base fee + unconditional cap either way — see
    // OscillonHook's no-usable-Chainlink branch). trustLevel() is still
    // computed per swap and carried on SwapContext, but nothing currently
    // branches on it.
    uint16 internal constant MIN_TWAP_OBSERVATIONS = 8;
    uint256 internal constant MIN_NEARBY_DEPTH_BPS = 1000; // 10%
    int24 internal constant TRUST_CHECK_TICK_BAND = 60;

    // Revenue split
    uint256 internal constant PROTOCOL_FEE_BPS = 15;
    uint256 internal constant LP_FEE_BPS = 85;

    // Liquidity tier for K selection
    // uint256 internal constant THIN_POOL_LIQUIDITY = 500_000e6;
    uint256 internal constant K_THIN = 60;
    uint256 internal constant K_STANDARD = 45;
}
