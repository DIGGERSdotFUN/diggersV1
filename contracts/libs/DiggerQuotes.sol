// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {DiggerV4, IPoolManagerLite} from "./DiggerV4.sol";

/**
 * @title DiggerQuotes
 * @notice View-only swap quotes kept out of the `Diggers` runtime.
 * @author BasedDopamine
 */
library DiggerQuotes {
    /// @notice Fee-inclusive exact-input quote for one pool step.
    function quoteExactInput(
        address poolManager,
        IPoolManagerLite.PoolKey memory key,
        bool zeroForOne,
        uint256 amountIn
    ) external view returns (uint256 amountOut) {
        (amountOut,) = DiggerV4.quoteExactInputSingle(poolManager, key, zeroForOne, amountIn);
    }
}
