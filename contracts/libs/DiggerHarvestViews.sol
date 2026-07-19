// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {DiggerV4} from "./DiggerV4.sol";

/**
 * @title DiggerHarvestViews
 * @notice Pending-fee reads for opportunistic harvest gating.
 * @author BasedDopamine
 */
library DiggerHarvestViews {
    /// @notice True when accrued ETH or token fees exceed the configured floors.
    function shouldHarvest(
        address poolManager,
        bytes32 poolId,
        address owner,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt,
        uint256 ethThresholdWei,
        uint256 tokenThreshold
    ) external view returns (bool) {
        (uint256 pendingEth, uint256 pendingToken) =
            DiggerV4.getPendingV4Fees(poolManager, poolId, owner, tickLower, tickUpper, salt);
        return pendingEth >= ethThresholdWei || pendingToken >= tokenThreshold;
    }

    /// @notice Exact uncollected LP fees (ETH, token) awaiting the next harvest. For
    ///         indexer reconciliation of the harvestable pot — not a per-pageview read.
    function pendingFees(
        address poolManager,
        bytes32 poolId,
        address owner,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt
    ) external view returns (uint256 ethFees, uint256 tokenFees) {
        (ethFees, tokenFees) = DiggerV4.getPendingV4Fees(poolManager, poolId, owner, tickLower, tickUpper, salt);
    }
}
