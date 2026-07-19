// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {DiggerGraduationMath} from "./DiggerGraduationMath.sol";
import {IDiggers} from "../interfaces/IDiggers.sol";
import {IDiggersToken} from "../interfaces/IDiggersToken.sol";

/**
 * @title DiggerGraduationLib
 * @notice Graduation orchestration executed via `delegatecall` from `Diggers`. Graduation
 *         is criteria-only (no claim window, no owner, no maintenance eviction): a token
 *         that meets the three thresholds sets its `graduatedAt` flag, and if it is still
 *         in its first 24h it freely reserves any object it was the FIRST to mint. The
 *         explicit {graduate} reverts on failure; {autoReserve} (called from the buy/sell
 *         path) is silent so it can never break a trade.
 * @dev Storage-pointer parameters resolve in Diggers' context; no state lives here.
 * @author BasedDopamine
 */
library DiggerGraduationLib {
    /**
     * @notice Graduate `token` explicitly (permissionless, callable anytime).
     * @dev Reverts `AlreadyGraduated` if done, `CriteriaNotMet` if short. Usually
     *      unnecessary — a first-minter token auto-graduates on its next in-window trade.
     * @param registry The one shared name-object registry (storage pointer).
     * @param graduatedAt Per-token graduation timestamp (storage pointer).
     * @param tokenKeys Per-token object record (storage pointer).
     * @param token The token to graduate.
     */
    function graduate(
        mapping(bytes32 => IDiggers.KeyState) storage registry,
        mapping(address => uint64) storage graduatedAt,
        mapping(address => IDiggers.TokenKeys) storage tokenKeys,
        address token
    ) external {
        IDiggers.TokenKeys memory k = tokenKeys[token];
        if (k.nameKey == bytes32(0)) revert IDiggers.UnknownToken();
        if (graduatedAt[token] != 0) revert IDiggers.AlreadyGraduated();

        (uint32 holders, uint256 volumeEth, int24 meanTick, uint16 daysTracked) =
            IDiggersToken(token).graduationStats();
        (bool ok, uint256 avgMcapEth,,,) =
            DiggerGraduationMath.evaluate(holders, volumeEth, meanTick, daysTracked);
        if (!ok) revert IDiggers.CriteriaNotMet();

        _apply(registry, graduatedAt, k, token, holders, volumeEth, avgMcapEth);
    }

    /**
     * @notice Silent auto-graduation, called from `Diggers._trade` after each buy/sell.
     * @dev No-ops (never reverts) unless ALL hold: not yet graduated, within the token's
     *      first 24h, and the token is the `firstMinter` of at least one of its objects,
     *      and the criteria pass. On success it graduates + reserves the firstMinter
     *      objects, so a first-minter token needs no manual {graduate}.
     * @param registry The one shared name-object registry (storage pointer).
     * @param graduatedAt Per-token graduation timestamp (storage pointer).
     * @param tokenKeys Per-token object record (storage pointer).
     * @param token The token just traded.
     */
    function autoReserve(
        mapping(bytes32 => IDiggers.KeyState) storage registry,
        mapping(address => uint64) storage graduatedAt,
        mapping(address => IDiggers.TokenKeys) storage tokenKeys,
        address token
    ) external {
        if (graduatedAt[token] != 0) return;

        IDiggers.TokenKeys memory k = tokenKeys[token];
        if (k.nameKey == bytes32(0)) return;

        if (block.timestamp >= uint256(IDiggersToken(token).DEPLOYED_AT()) + DiggerGraduationMath.GRAD_FREE_WINDOW) {
            return;
        }
        if (registry[k.nameKey].firstMinter != token && registry[k.symbolKey].firstMinter != token) return;

        (uint32 holders, uint256 volumeEth, int24 meanTick, uint16 daysTracked) =
            IDiggersToken(token).graduationStats();
        (bool ok, uint256 avgMcapEth,,,) =
            DiggerGraduationMath.evaluate(holders, volumeEth, meanTick, daysTracked);
        if (!ok) return;

        _apply(registry, graduatedAt, k, token, holders, volumeEth, avgMcapEth);
    }

    /**
     * @notice Read-only graduation progress for `token`.
     * @dev See {IDiggers.graduationProgress}.
     */
    function progress(
        mapping(bytes32 => IDiggers.KeyState) storage registry,
        mapping(address => IDiggers.TokenKeys) storage tokenKeys,
        address token
    )
        external
        view
        returns (
            uint32 holders,
            uint256 volumeEth,
            uint256 avgMcapEth,
            uint64 freeWindowEndsAt,
            uint64 reservedUntil,
            bool[3] memory passes
        )
    {
        IDiggers.TokenKeys memory k = tokenKeys[token];
        if (k.nameKey == bytes32(0)) revert IDiggers.UnknownToken();

        int24 meanTick;
        uint16 daysTracked;
        (holders, volumeEth, meanTick, daysTracked) = IDiggersToken(token).graduationStats();

        (, avgMcapEth, passes[0], passes[1], passes[2]) =
            DiggerGraduationMath.evaluate(holders, volumeEth, meanTick, daysTracked);

        freeWindowEndsAt = IDiggersToken(token).DEPLOYED_AT() + DiggerGraduationMath.GRAD_FREE_WINDOW;

        uint64 nameUntil = registry[k.nameKey].reservationUntil;
        uint64 symUntil = registry[k.symbolKey].reservationUntil;
        reservedUntil = nameUntil < symUntil ? nameUntil : symUntil; // both objects held until min
    }

    // -------------------------------------------------------------- internal

    /// @dev Marks `token` graduated and, if still in its first 24h, freely reserves each
    ///      object it was the first to mint (to `deployedAt + 24h`). Emits {Graduated}.
    function _apply(
        mapping(bytes32 => IDiggers.KeyState) storage registry,
        mapping(address => uint64) storage graduatedAt,
        IDiggers.TokenKeys memory k,
        address token,
        uint32 holders,
        uint256 volumeEth,
        uint256 avgMcapEth
    ) private {
        graduatedAt[token] = uint64(block.timestamp);

        uint64 freeEnd = IDiggersToken(token).DEPLOYED_AT() + DiggerGraduationMath.GRAD_FREE_WINDOW;
        if (block.timestamp < freeEnd) {
            _bonus(registry[k.nameKey], token, freeEnd);
            if (k.symbolKey != k.nameKey) _bonus(registry[k.symbolKey], token, freeEnd);
        }

        emit IDiggers.Graduated(token, k.nameKey, k.symbolKey, holders, volumeEth, avgMcapEth);
    }

    /// @dev Free 24h hold: only the object's original minter earns it, and only advances.
    function _bonus(IDiggers.KeyState storage ks, address token, uint64 freeEnd) private {
        if (ks.firstMinter == token && freeEnd > ks.reservationUntil) ks.reservationUntil = freeEnd;
    }
}
