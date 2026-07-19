// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {DiggerV4} from "./DiggerV4.sol";
import {DiggerMath} from "./DiggerMath.sol";

/**
 * @title DiggerGraduationMath
 * @notice Pure graduation criteria: the three ETH-denominated thresholds and the
 *         mean-tick market-cap conversion. No oracle — everything is derived from the
 *         pool's own price and constants.
 * @dev `internal` on purpose so these inline into whichever library links them (the
 *      registry lib for maintenance, the graduation lib for `graduate`/`progress`),
 *      keeping them off the `Diggers` singleton runtime. Market cap reuses
 *      `DiggerV4.sqrtPriceToInversePrice` (1e18-scaled ETH-per-token) — the exact price
 *      convention the token uses for `volumeEthCum` — so graduation and volume agree.
 * @author BasedDopamine
 */
library DiggerGraduationMath {
    /// @dev Minimum unique pool-verified holders.
    uint32 internal constant GRAD_HOLDERS = 500;

    /// @dev Minimum cumulative ETH-equivalent volume (wei).
    uint256 internal constant GRAD_VOLUME_ETH = 540 ether;

    /// @dev Minimum ≤7-day mean-tick market cap (wei).
    uint256 internal constant GRAD_MCAP_ETH = 270 ether;

    /// @dev Fixed launch supply — must match DiggersToken.TOTAL_SUPPLY.
    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000e18;

    /// @dev Free graduation window from a token's own launch.
    uint64 internal constant GRAD_FREE_WINDOW = 24 hours;

    /**
     * @notice Market cap (wei) implied by a mean daily-close tick.
     * @dev `mcap = TOTAL_SUPPLY × ethPerToken`, where `ethPerToken` is the 1e18-scaled
     *      inverse spot price at the tick. Returns 0 for a zero/uninitialized price.
     * @param meanTick Mean of the recorded daily closes.
     * @return mcapEth Implied fully-diluted market cap in wei.
     */
    function mcapEthAtTick(int24 meanTick) internal pure returns (uint256 mcapEth) {
        uint160 sqrtP = DiggerV4.getSqrtRatioAtTick(meanTick);
        uint256 ethPerToken = DiggerV4.sqrtPriceToInversePrice(sqrtP); // 1e18-scaled
        mcapEth = DiggerMath.md512(TOTAL_SUPPLY, ethPerToken, 1e18);
    }

    /**
     * @notice Evaluates the three graduation criteria from a token's stats.
     * @param holders Unique pool-verified holders.
     * @param volumeEth Cumulative ETH-equivalent volume (wei).
     * @param meanTick Mean of the recorded daily closes.
     * @param daysTracked Non-empty days that entered the mean (0 ⇒ no price data yet).
     * @return ok True iff all three criteria pass.
     * @return avgMcapEth Implied mean-tick market cap (wei); 0 when `daysTracked == 0`.
     * @return holdersPass Holder-count criterion.
     * @return volumePass Volume criterion.
     * @return mcapPass Market-cap criterion.
     */
    function evaluate(uint32 holders, uint256 volumeEth, int24 meanTick, uint16 daysTracked)
        internal
        pure
        returns (bool ok, uint256 avgMcapEth, bool holdersPass, bool volumePass, bool mcapPass)
    {
        holdersPass = holders >= GRAD_HOLDERS;
        volumePass = volumeEth >= GRAD_VOLUME_ETH;
        avgMcapEth = daysTracked == 0 ? 0 : mcapEthAtTick(meanTick);
        mcapPass = avgMcapEth >= GRAD_MCAP_ETH;
        ok = holdersPass && volumePass && mcapPass;
    }
}
