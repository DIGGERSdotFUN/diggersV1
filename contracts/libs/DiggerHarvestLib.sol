// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {DiggerHarvestMath} from "./DiggerHarvestMath.sol";
import {DiggersToken} from "../DiggersToken.sol";
import {IDiggers} from "../interfaces/IDiggers.sol";

/**
 * @title DiggerHarvestLib
 * @notice Harvest orchestration executed via `delegatecall` from `Diggers`, so its
 *         bytecode lives off the singleton while it still reads and writes the
 *         launchpad's own storage (ETH-owed ledger, per-token retry pot, creator
 *         fee-split table). Under delegatecall `address(this)` is the launchpad, so the
 *         ETH pushes below spend the singleton's balance (the fees it just collected).
 * @dev Payouts are PUSH, not pull: each ETH slice is delivered with a gas-capped
 *      low-level call so a recipient that reverts OR burns gas can never block the
 *      harvest (and therefore never block trades, since harvest runs opportunistically
 *      inside buy/sell). Fallback chain — creator rows: recipient → fee owner → the
 *      per-token retry pot; team/platform: recipient → the pull ledger (they are fixed
 *      protocol addresses). The pull ledger (`ethOwed`/`claim`) is retained for those
 *      protocol fallbacks, the name registry's reservation proceeds, and DiggersCoin's
 *      LP funding. State never lives here; only the code does.
 * @author BasedDopamine
 */
library DiggerHarvestLib {
    /// @dev Gas forwarded to each ETH push. Enough for an EOA or a lean receiver; a
    ///      recipient needing more (or hostile) falls through the chain instead of
    ///      reverting the harvest. A bare bool/try check does NOT bound gas — this does.
    uint256 private constant PUSH_GAS = 40_000;

    /**
     * @notice Splits collected fees and delivers them (gas-capped push + burn/pot).
     * @param ethOwed Diggers' pull-payment ETH ledger (storage pointer) — team/platform
     *        push fallback, plus registry/DiggersCoin usage elsewhere.
     * @param pendingEth Diggers' per-token creator retry pot (storage pointer).
     * @param feeSplits The token's creator fee-split rows (storage pointer).
     * @param count Number of active fee-split rows.
     * @param teamTreasury Current team recipient (owner-editable).
     * @param feeOwner The token's fee-split owner — creator-push fallback (0 = renounced).
     * @param token Launched token whose fees were collected.
     * @param caller Original harvest caller (for the event).
     * @param ethFees Freshly collected ETH fees (wei).
     * @param carriedPending Creator-side ETH carried from prior failed pushes (wei); added
     *        to the creator side only, so it is never re-taxed by team/platform.
     * @param tokenFees Collected token fees (18 dec).
     * @param burnShareWad The token's burn share (1e18-scaled); the pot takes the remainder.
     * @param teamShareWad The owner-set team share of ETH fees (1e18-scaled).
     * @param platformToken The platform coin — receives the windowed 10% ETH slice.
     * @param inWindow Whether the launch airdrop window is still open (drives the split).
     */
    function distribute(
        mapping(address => uint256) storage ethOwed,
        mapping(address => uint256) storage pendingEth,
        mapping(uint256 => IDiggers.FeeSplit) storage feeSplits,
        uint8 count,
        address teamTreasury,
        address feeOwner,
        address token,
        address caller,
        uint256 ethFees,
        uint256 carriedPending,
        uint256 tokenFees,
        uint256 burnShareWad,
        uint256 teamShareWad,
        address platformToken,
        bool inWindow
    ) external {
        (uint256 ethToTeam, uint256 ethToPlatform, uint256 ethToCreators) =
            DiggerHarvestMath.splitEthWindowed(ethFees, teamShareWad, inWindow);
        // Retried creator wei rides the creator side only (already net of team/platform).
        ethToCreators += carriedPending;

        // Team + platform: push, else fall back to the pull ledger (they are protocol
        // addresses; DiggersCoin reads `ethOwed(self)` and the registry credits team here).
        if (ethToTeam > 0 && !_push(teamTreasury, ethToTeam)) ethOwed[teamTreasury] += ethToTeam;
        if (ethToPlatform > 0 && !_push(platformToken, ethToPlatform)) ethOwed[platformToken] += ethToPlatform;

        // Creators: push to recipient → fee owner → park in the per-token retry pot.
        uint256 allocated;
        for (uint8 i = 0; i < count; ++i) {
            IDiggers.FeeSplit storage row = feeSplits[i];
            uint256 slice = DiggerHarvestMath.shareOf(ethToCreators, row.share, i == count - 1, allocated);
            allocated += slice;
            if (slice == 0) continue;
            if (_push(row.to, slice)) continue;
            if (feeOwner != address(0) && _push(feeOwner, slice)) continue;
            pendingEth[token] += slice;
            emit IDiggers.FeeParked(token, row.to, slice);
        }

        uint256 burned;
        uint256 toPot;
        if (tokenFees > 0) {
            (burned, toPot) = DiggerHarvestMath.splitToken(tokenFees, burnShareWad);
            if (burned > 0) DiggersToken(token).burn(burned);
            if (toPot > 0) DiggersToken(token).transfer(token, toPot);
        }

        emit IDiggers.Harvested(
            token, caller, ethFees + carriedPending, ethToTeam, ethToPlatform, ethToCreators, burned, toPot
        );
    }

    /// @dev Gas-capped ETH send from the launchpad's balance. Returns success; never
    ///      reverts on a failing recipient so the caller can fall through its chain.
    function _push(address to, uint256 amount) private returns (bool ok) {
        (ok,) = payable(to).call{value: amount, gas: PUSH_GAS}("");
    }
}
