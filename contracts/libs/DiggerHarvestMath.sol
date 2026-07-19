// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {DiggerMath} from "./DiggerMath.sol";

/**
 * @title DiggerHarvestMath
 * @notice Pure 1e18-scaled harvest split math kept out of the `Diggers` runtime.
 * @author BasedDopamine
 */
library DiggerHarvestMath {
    uint256 internal constant WAD = 1e18;

    /// @dev Platform-token slice active only during the launch airdrop window: 10% of ETH
    ///      fees, carved out of the TEAM side to fund the coin LP. The owner-set
    ///      `teamShareWad` is guaranteed >= this while the window is open.
    uint256 internal constant PLATFORM_SHARE_WAD = 1e17;

    /// @notice Windowed ETH split with an owner-set team share. The creator side is always
    ///         `ethTotal - floor(ethTotal * teamShareWad / 1e18)`. During the airdrop
    ///         window a fixed 10% is carved OUT OF the team side and routed to the platform
    ///         coin (team keeps `teamShare - 10%`, creator is unaffected); afterwards
    ///         `toPlatform == 0`. Team and platform are floored; the creator side absorbs
    ///         the rounding dust so the whole `ethTotal` is always conserved.
    /// @dev Caller guarantees `teamShareWad <= 1e18`, and `teamShareWad >= 1e17` whenever
    ///      `inWindow` is true, so `toTeam` never underflows.
    function splitEthWindowed(uint256 ethTotal, uint256 teamShareWad, bool inWindow)
        external
        pure
        returns (uint256 toTeam, uint256 toPlatform, uint256 toCreators)
    {
        uint256 teamTotal = DiggerMath.md512(ethTotal, teamShareWad, WAD);
        toPlatform = inWindow ? DiggerMath.md512(ethTotal, PLATFORM_SHARE_WAD, WAD) : 0;
        toTeam = teamTotal - toPlatform;
        toCreators = ethTotal - teamTotal;
    }

    /// @notice Splits collected token fees per the token's creator-chosen burn share
    ///         (1e18-scaled). Burn floors; the airdrop pot takes the remainder.
    function splitToken(uint256 tokenTotal, uint256 burnShareWad)
        external
        pure
        returns (uint256 toBurn, uint256 toPot)
    {
        toBurn = DiggerMath.md512(tokenTotal, burnShareWad, WAD);
        toPot = tokenTotal - toBurn;
    }

    /// @notice Credits one creator-table share (floor); last entry gets dust.
    function shareOf(uint256 creatorTotal, uint256 shareWad, bool isLast, uint256 allocatedSoFar)
        external
        pure
        returns (uint256 amount)
    {
        if (isLast) return creatorTotal - allocatedSoFar;
        return DiggerMath.md512(creatorTotal, shareWad, WAD);
    }
}
