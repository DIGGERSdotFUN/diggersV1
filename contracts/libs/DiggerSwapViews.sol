// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {DiggerV4} from "./DiggerV4.sol";

/**
 * @title DiggerSwapViews
 * @notice Post-trade pool reads for the rich `Swapped` event. Deployed as a linked
 *         library so swap hot paths stay out of the `Diggers` runtime.
 * @author BasedDopamine
 */
library DiggerSwapViews {
    struct State {
        uint160 sqrtPriceX96;
        int24 tick;
        uint128 liquidity;
        uint256 ethInPool;
        uint256 tokenInPool;
    }

    /// @notice Slot0, liquidity, and virtual reserves after a swap.
    function afterSwap(
        address poolManager,
        bytes32 poolId,
        int24 startTick,
        int24 maxTick
    ) external view returns (State memory s) {
        DiggerV4.Slot0 memory slot0 = DiggerV4.getSlot0(poolManager, poolId);
        s.sqrtPriceX96 = slot0.sqrtPriceX96;
        s.tick = slot0.tick;
        s.liquidity = DiggerV4.getPoolLiquidity(poolManager, poolId);
        uint160 sqrtStart = DiggerV4.getSqrtRatioAtTick(startTick);
        uint160 sqrtMax = DiggerV4.getSqrtRatioAtTick(maxTick);
        (s.ethInPool, s.tokenInPool) =
            DiggerV4.getAmountsForLiquidity(s.sqrtPriceX96, sqrtStart, sqrtMax, s.liquidity);
    }
}
