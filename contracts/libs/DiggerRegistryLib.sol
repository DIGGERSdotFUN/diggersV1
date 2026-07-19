// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {DiggerCharset} from "./DiggerCharset.sol";
import {DiggerGraduationMath} from "./DiggerGraduationMath.sol";
import {IDiggers} from "../interfaces/IDiggers.sol";
import {IDiggersToken} from "../interfaces/IDiggersToken.sol";

/**
 * @title DiggerRegistryLib
 * @notice Name registry logic executed via `delegatecall` from `Diggers`, so its bytecode
 *         lives off the singleton while it reads and writes the launchpad's registry
 *         storage. There is NO name-vs-symbol distinction: a token's folded name and
 *         folded symbol are both keys in ONE shared `registry` set of "name objects", and
 *         each object carries a single reservation clock (`reservationUntil`).
 * @dev Storage-pointer parameters resolve in Diggers' context under delegatecall; no state
 *      lives in this library. Creation is gated ONLY by each object's clock — it does not
 *      matter who reserved it. The clock only ever advances: a 1h auto-lock on every
 *      create, the first-minter 24h graduation bonus (in {DiggerGraduationLib}), and paid
 *      {extend}. A token holds two objects; a name==symbol collision is a single object.
 * @author BasedDopamine
 */
library DiggerRegistryLib {
    /// @dev Unconditional per-create lock — every create reserves its objects for 1h.
    uint64 private constant LAUNCH_LOCK = 1 hours;

    /// @dev Linear reservation rate: 1 ETH (1e18 wei) buys 365 days.
    uint256 private constant SECONDS_PER_ETH = 365 days;

    /// @dev Reservation hard cap: 100 years out from now.
    uint256 private constant MAX_RESERVATION = 100 * 365 days;

    /**
     * @notice Charset-validates both strings and runs the creation gate.
     * @dev The whole gate: each object is blocked iff `now < reservationUntil`. No owner
     *      lookup, no contender scan — it does not matter who reserved it. Reverts with a
     *      field-specific error; otherwise returns the folded objects the caller passes
     *      back to {appendContender} after the token is deployed.
     * @param registry The one shared name-object registry (storage pointer).
     * @param name Raw name string.
     * @param symbol Raw symbol string.
     * @return nameKey Case-folded name object.
     * @return symbolKey Case-folded symbol object.
     */
    function precheck(
        mapping(bytes32 => IDiggers.KeyState) storage registry,
        string calldata name,
        string calldata symbol
    ) external view returns (bytes32 nameKey, bytes32 symbolKey) {
        nameKey = DiggerCharset.nameKey(name);
        symbolKey = DiggerCharset.symbolKey(symbol);

        if (block.timestamp < registry[nameKey].reservationUntil) revert IDiggers.NameReserved();
        if (block.timestamp < registry[symbolKey].reservationUntil) revert IDiggers.SymbolReserved();
    }

    /**
     * @notice Permanently reserves a name + symbol pair so no token can ever launch with
     *         them — the platform brand guard. Sets both objects' `reservationUntil` to the
     *         uint64 max, so the creation gate always reverts. Called once from the `Diggers`
     *         constructor; no code path ever lowers `reservationUntil`, so the block is
     *         irreversible.
     * @param registry The one shared name-object registry (storage pointer).
     * @param name Raw name to block (charset-validated + case-folded).
     * @param symbol Raw symbol to block (charset-validated + case-folded).
     */
    function reserveForever(
        mapping(bytes32 => IDiggers.KeyState) storage registry,
        string calldata name,
        string calldata symbol
    ) external {
        registry[DiggerCharset.nameKey(name)].reservationUntil = type(uint64).max;
        registry[DiggerCharset.symbolKey(symbol)].reservationUntil = type(uint64).max;
    }

    /**
     * @notice Records `token` on both of its objects and (re)arms their 1h creation lock.
     * @dev Every create — first minter or later copy — advances `reservationUntil` to at
     *      least `now + 1h`. `firstMinter` is set once, permanently, only when the object
     *      was never created before; it is the only token that later earns the free 24h
     *      graduation hold. A name==symbol collision is processed once.
     * @param registry The one shared name-object registry (storage pointer).
     * @param tokenKeys Per-token object record (storage pointer).
     * @param token The freshly deployed token.
     * @param nameKey Case-folded name object from {precheck}.
     * @param symbolKey Case-folded symbol object from {precheck}.
     */
    function appendContender(
        mapping(bytes32 => IDiggers.KeyState) storage registry,
        mapping(address => IDiggers.TokenKeys) storage tokenKeys,
        address token,
        bytes32 nameKey,
        bytes32 symbolKey
    ) external {
        uint64 lockUntil = uint64(block.timestamp) + LAUNCH_LOCK;

        _arm(registry[nameKey], token, lockUntil);
        if (symbolKey != nameKey) _arm(registry[symbolKey], token, lockUntil);

        tokenKeys[token] = IDiggers.TokenKeys({nameKey: nameKey, symbolKey: symbolKey});

        emit IDiggers.Contender(nameKey, symbolKey, token, lockUntil);
    }

    /**
     * @notice Extends the reservation on both of a graduated token's objects.
     * @dev The token MUST be graduated AND still pass all three criteria right now
     *      (`NotGraduated` otherwise). Each object's clock advances `max(current, now) +
     *      bought` — payments compound, the clock is never reset down. One payment covers
     *      both objects. Proceeds credit the team via the pull ledger.
     * @param registry The one shared name-object registry (storage pointer).
     * @param graduatedAt Per-token graduation timestamp (storage pointer).
     * @param tokenKeys Per-token object record (storage pointer).
     * @param ethOwed Diggers' pull-payment ETH ledger (storage pointer).
     * @param teamTreasury Reservation proceeds recipient.
     * @param token The graduated token being reserved for.
     * @param value ETH paid (wei).
     */
    function extend(
        mapping(bytes32 => IDiggers.KeyState) storage registry,
        mapping(address => uint64) storage graduatedAt,
        mapping(address => IDiggers.TokenKeys) storage tokenKeys,
        mapping(address => uint256) storage ethOwed,
        address teamTreasury,
        address token,
        uint256 value
    ) external {
        IDiggers.TokenKeys memory k = tokenKeys[token];
        if (k.nameKey == bytes32(0)) revert IDiggers.UnknownToken();

        if (graduatedAt[token] == 0 || !_livePasses(token)) revert IDiggers.NotGraduated();

        uint256 bought = value * SECONDS_PER_ETH / 1e18;
        if (bought == 0) revert IDiggers.ZeroReservation();

        uint64 nameUntil = _bump(registry[k.nameKey], bought);
        uint64 symUntil = k.symbolKey == k.nameKey ? nameUntil : _bump(registry[k.symbolKey], bought);

        ethOwed[teamTreasury] += value;

        emit IDiggers.ReservationExtended(k.nameKey, k.symbolKey, token, msg.sender, value, nameUntil, symUntil);
    }

    // ---------------------------------------------------------------- views

    /// @notice Whether a name could be created right now (its object's clock has lapsed).
    function isNameFree(mapping(bytes32 => IDiggers.KeyState) storage registry, string calldata name)
        external
        view
        returns (bool)
    {
        return block.timestamp >= registry[DiggerCharset.nameKey(name)].reservationUntil;
    }

    /// @notice Whether a symbol could be created right now (its object's clock has lapsed).
    function isSymbolFree(mapping(bytes32 => IDiggers.KeyState) storage registry, string calldata symbol)
        external
        view
        returns (bool)
    {
        return block.timestamp >= registry[DiggerCharset.symbolKey(symbol)].reservationUntil;
    }

    /// @notice Registry state for a name object and a symbol object (same shared set).
    function keyStateOf(
        mapping(bytes32 => IDiggers.KeyState) storage registry,
        string calldata name,
        string calldata symbol
    ) external view returns (IDiggers.KeyState memory nameState, IDiggers.KeyState memory symbolState) {
        nameState = registry[DiggerCharset.nameKey(name)];
        symbolState = registry[DiggerCharset.symbolKey(symbol)];
    }

    // -------------------------------------------------------------- internal

    /// @dev Arms one object on create: record the first minter once, push the contender,
    ///      and advance the clock to at least `now + 1h`.
    function _arm(IDiggers.KeyState storage ks, address token, uint64 lockUntil) private {
        if (ks.firstMinter == address(0)) ks.firstMinter = token;
        ks.contenders.push(token);
        if (lockUntil > ks.reservationUntil) ks.reservationUntil = lockUntil;
    }

    /// @dev Advances one object's clock: `max(current, now) + bought`, capped at now+100y.
    function _bump(IDiggers.KeyState storage ks, uint256 bought) private returns (uint64 until) {
        uint256 base = ks.reservationUntil;
        if (base < block.timestamp) base = block.timestamp;
        uint256 stamp = base + bought;
        if (stamp > block.timestamp + MAX_RESERVATION) revert IDiggers.TooLong();
        until = uint64(stamp);
        ks.reservationUntil = until;
    }

    /// @dev True iff `token` still meets all three graduation criteria right now.
    function _livePasses(address token) private view returns (bool ok) {
        (uint32 holders, uint256 volumeEth, int24 meanTick, uint16 daysTracked) =
            IDiggersToken(token).graduationStats();
        (ok,,,,) = DiggerGraduationMath.evaluate(holders, volumeEth, meanTick, daysTracked);
    }
}
