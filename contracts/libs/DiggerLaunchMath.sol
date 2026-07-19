// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {DiggerV4} from "./DiggerV4.sol";

/**
 * @title DiggerLaunchMath
 * @notice Pure helpers for deriving the spacing-aligned launch tick off-chain or in
 *         deploy harnesses. Kept out of `Diggers` runtime to save bytecode.
 * @author BasedDopamine
 */
library DiggerLaunchMath {
    /// @notice Spacing-aligned tick whose sqrt ratio is ≤ `sqrtPriceX96`.
    function alignedStartTick(uint160 sqrtPriceX96, int24 spacing) internal pure returns (int24) {
        return alignTickDown(tickFromSqrt(sqrtPriceX96), spacing);
    }

    /// @dev Rounds a tick down to the nearest spacing multiple (toward −∞).
    function alignTickDown(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 r = tick % spacing;
        if (r == 0) return tick;
        return tick - r;
    }

    /// @dev Largest tick whose sqrt ratio is ≤ `sqrtPriceX96` (binary search).
    function tickFromSqrt(uint160 sqrtPriceX96) internal pure returns (int24 tick) {
        int24 lo = -887272;
        int24 hi = 887272;
        while (lo < hi) {
            int24 mid = int24((int256(lo) + int256(hi) + 1) / 2);
            if (DiggerV4.getSqrtRatioAtTick(mid) <= sqrtPriceX96) lo = mid;
            else hi = mid - 1;
        }
        return lo;
    }
}
