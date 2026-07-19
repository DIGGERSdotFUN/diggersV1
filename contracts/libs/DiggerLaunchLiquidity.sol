// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {DiggerV4} from "./DiggerV4.sol";

/**
 * @title DiggerLaunchLiquidity
 * @notice Create-time liquidity search kept out of the `Diggers` runtime.
 * @author BasedDopamine
 */
library DiggerLaunchLiquidity {
    /// @dev Maximum liquidity mintable without exceeding a token1 budget.
    function maxLiquidityForAmount1(uint160 sqrtLower, uint160 sqrtUpper, uint256 budget)
        external
        pure
        returns (uint128)
    {
        uint128 lo;
        uint128 hi = DiggerV4.getLiquidityForAmount1Up(sqrtLower, sqrtUpper, budget);
        uint128 best;
        while (lo <= hi) {
            uint128 mid = lo + (hi - lo) / 2;
            if (DiggerV4.getAmount1ForLiquidity(sqrtLower, sqrtUpper, mid) <= budget) {
                best = mid;
                lo = mid + 1;
            } else {
                if (mid == 0) break;
                hi = mid - 1;
            }
        }
        return best;
    }
}
