// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IOscillonOracle} from "../IOscillonOracle.sol";
import {OracleAnswerInvalid, OracleStale} from "../../errors/OscillonErrors.sol";

/// @notice Minimal subset of Pyth's on-chain interface — just the pieces
///         PythAdapter needs. Defined locally instead of pulling in the full
///         pyth-sdk-solidity package (pythnetwork org on npm/GitHub), which
///         is not installed in this repo; this keeps the skeleton
///         self-contained and compiling without adding a new supply-chain
///         dependency this close to submission.
interface IPyth {
    struct Price {
        int64 price;
        uint64 conf;
        int32 expo;
        uint256 publishTime;
    }

    /// @dev Reverts if the cached price is older than `age` seconds — Pyth is
    ///      pull-based, so this reverts unless someone has called
    ///      `updatePriceFeeds()` on this contract recently enough. Unlike
    ///      Chainlink, freshness here is not maintained automatically.
    function getPriceNoOlderThan(
        bytes32 id,
        uint256 age
    ) external view returns (Price memory price);
}

/// @title PythAdapter — SKELETON, NOT WIRED IN
/// @notice IOscillonOracle wrapper for a Pyth pull-based price feed.
/// @dev NOT approved via approveAdapter and NOT referenced by any
///      registerPool call in this repo — see DeployOscillon.s.sol and
///      THREAT_MODEL.md §4 (Explicitly out of scope). Demonstrates that
///      IOscillonOracle is source-agnostic without taking on Pyth's
///      operational requirements before they're actually needed:
///        - someone (keeper or the swap caller) must push a fresh price via
///          `updatePriceFeeds()` before every read that needs it, and pay
///          Pyth's per-update fee — Oscillon has no keeper infra today
///        - the confidence-interval mapping below is illustrative, not
///          calibrated against any backtest
///        - wiring this in for real means extending TokenOracleConfig and
///          OscillonPriceEngine's two-source cascade to a third source,
///          which is a real design change, not a drop-in
contract PythAdapter is IOscillonOracle {
    IPyth public immutable pyth;
    bytes32 public immutable priceId;
    uint256 public immutable maxAge; // Pyth pull feeds: typically ~60s, not comparable to Chainlink's push heartbeat

    constructor(address _pyth, bytes32 _priceId, uint256 _maxAge) {
        pyth = IPyth(_pyth);
        priceId = _priceId;
        maxAge = _maxAge;
    }

    function getPrice()
        external
        view
        override
        returns (uint256 price1e18, uint256 confidence)
    {
        // Reverts if nobody has pushed a fresh update within maxAge — this
        // is the pull-model cost: Oscillon's price cascade (OscillonPriceEngine)
        // already treats an adapter revert as "fall through to TWAP," so an
        // un-kept-fresh Pyth feed degrades safely the same way a stale
        // Chainlink feed does, it just reverts far more often without a
        // keeper actively maintaining it.
        IPyth.Price memory p = pyth.getPriceNoOlderThan(priceId, maxAge);

        if (p.price <= 0) revert OracleAnswerInvalid();
        if (p.expo > 0) revert OracleAnswerInvalid(); // Pyth expo is normally negative; a positive expo here is not a shape this adapter has been built for

        price1e18 = _scaleTo1e18(uint256(uint64(p.price)), p.expo);

        // Illustrative only — not derived from any backtest or precedent.
        // Wider Pyth confidence interval -> treat as less trustworthy.
        confidence = p.conf < 100
            ? 95
            : p.conf < 500
                ? 70
                : p.conf < 2000
                    ? 40
                    : 10;
    }

    function isHealthy() external view override returns (bool) {
        try pyth.getPriceNoOlderThan(priceId, maxAge) returns (
            IPyth.Price memory p
        ) {
            return p.price > 0;
        } catch {
            return false;
        }
    }

    function _scaleTo1e18(
        uint256 rawPrice,
        int32 expo
    ) internal pure returns (uint256) {
        // Pyth prices are rawPrice * 10^expo; expo is typically negative
        // (e.g. -8), so target1e18 = rawPrice * 10^(18 + expo).
        int256 shift = int256(18) + int256(expo);
        if (shift < 0) revert OracleAnswerInvalid();
        return rawPrice * (10 ** uint256(shift));
    }
}
