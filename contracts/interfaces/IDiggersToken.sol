// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

/**
 * @title IDiggersToken
 * @notice Interface of the ERC20 deployed for every Diggers launch. Fixed 1e9·1e18
 *         supply, 18 decimals, burnable, non-mintable. The token natively trusts the
 *         Diggers launchpad as its swap router: transferFrom skips the allowance
 *         check when the launchpad is the caller, so sells never need an approve
 *         transaction. This file is self-contained (no implementation imports) so it
 *         can be consumed standalone.
 * @author BasedDopamine
 */
interface IDiggersToken {
    // ----------------------------------------------------------------- events

    /// @notice Standard ERC20 transfer event (also emitted for mint/burn legs).
    event Transfer(address indexed from, address indexed to, uint256 value);

    /// @notice Standard ERC20 approval event.
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /// @dev All other token events (PoolTrade, PointsCredited, LeaderboardChanged,
    ///      HolderCountChanged, EpochSettled, AirdropPaid, LockSet) are emitted by the
    ///      launchpad's event hub (see IDiggers), not the token, so the whole protocol's
    ///      non-ERC20 log stream lives on ONE address. The token forwards them via the
    ///      launchpad's guarded `log*` callbacks.

    // ----------------------------------------------------------------- errors

    /// @notice Sender balance is below the requested amount.
    error BalanceTooLow(uint256 balance, uint256 needed);

    /// @notice Spender allowance is below the requested amount.
    error AllowanceTooLow(uint256 allowance, uint256 needed);

    /// @notice First-day anti-whale: the transfer would push the recipient above 2%
    ///         of total supply.
    error CapExceeded();

    /// @notice Zero address where a real account is required.
    error ZeroAddress();

    /// @notice Caller must be the launchpad.
    error NotLaunchpad();

    /// @notice The address already has a lock (one per address, forever).
    error LockExists();

    /// @notice This token already carries the maximum number of locks (10).
    error TooManyLocks();

    /// @notice Lock total, duration, and tranches must all be non-zero.
    error LockParamsInvalid();

    /// @notice The transfer would dip into the sender's still-locked balance.
    error LockActive(uint256 lockedRemaining, uint256 balanceAfter);

    /// @notice `initialize` was already called on this clone (once, ever).
    error AlreadyInitialized();

    // ----------------------------------------------------------- initializer

    /**
     * @notice Arms a fresh EIP-1167 clone: identity, pool config, epoch clock, and the
     *         one and only supply mint (to the launchpad). Launchpad-only, once-only —
     *         called in the same tx as the clone's CREATE2, so an unarmed clone never
     *         exists on-chain.
     */
    function initialize(
        string calldata name_,
        string calldata symbol_,
        string calldata metadataURI_,
        uint24 poolFee_
    ) external;

    // ------------------------------------------------------------ ERC20 core

    function name() external view returns (string memory);

    function symbol() external view returns (string memory);

    function decimals() external pure returns (uint8);

    function totalSupply() external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);

    function transfer(address to, uint256 amount) external returns (bool);

    function allowance(address owner, address spender) external view returns (uint256);

    function approve(address spender, uint256 amount) external returns (bool);

    /**
     * @notice Standard transferFrom — EXCEPT when called by the Diggers launchpad.
     * @dev LOUD DISCLOSURE: when `msg.sender` is the launchpad (this token's factory,
     *      router, and sole LP), the allowance check is skipped entirely — nothing is
     *      read or written, so wallets and explorers show no allowance to revoke.
     *      The launchpad only ever pulls tokens from ITS OWN caller inside its swap
     *      entrypoints; it exposes no generic pull surface. Every other caller goes
     *      through the normal allowance path.
     */
    function transferFrom(address from, address to, uint256 amount) external returns (bool);

    /// @notice Burns `amount` from the caller, reducing total supply forever.
    ///         Locked balances cannot be burned.
    function burn(uint256 amount) external;

    // ---------------------------------------------------------- vesting locks

    /**
     * @notice Registers a tranche vesting lock for `holder` (launchpad-only, at
     *         token-creation time). Tokens stay in the holder's wallet; only their
     *         movement is gated. One lock per address ever; at most 10 per token.
     * @param holder Address whose balance becomes movement-gated.
     * @param total Locked amount (raw units, 18 dec).
     * @param duration Seconds until fully vested.
     * @param tranches Equal unlock slices (1 = cliff at duration).
     */
    function registerLock(address holder, uint128 total, uint64 duration, uint32 tranches) external;

    /// @notice Amount of `holder`'s balance still movement-locked right now.
    function lockRemaining(address holder) external view returns (uint256);

    /// @notice Full lock detail for one holder (total == 0 means no lock).
    function getLock(address holder)
        external
        view
        returns (uint128 total, uint64 start, uint64 duration, uint32 tranches, uint256 unlocked, uint256 remaining);

    /// @notice Every lock on this token (bounded at 10 entries).
    function getLocks()
        external
        view
        returns (
            address[] memory holders,
            uint128[] memory totals,
            uint256[] memory unlocked,
            uint256[] memory remaining
        );

    // ---------------------------------------------------------- trader points

    /// @notice Current points epoch id (bumps on each lazy daily settlement).
    function epoch() external view returns (uint256);

    /// @notice Deadline of the current epoch; the first transfer at or past it
    ///         settles the day. Anchored to the trigger, not a fixed daily grid.
    function epochEnd() external view returns (uint64);

    /// @notice Points of `trader` in the current epoch, 1e18-scaled. Buys through
    ///         the pool earn 2e18·amount/supply, sells 5e17·amount/supply (a buy is
    ///         worth 4x the same-size sell). Only pool legs earn points.
    function traderPoints(address trader) external view returns (uint256);

    /// @notice Points of `trader` in an arbitrary (incl. past) epoch.
    function pointsOf(uint256 epochId, address trader) external view returns (uint256);

    /// @notice All-time points `trader` has earned across every epoch, 1e18-scaled.
    ///         Cosmetic ("digger score") only — the daily airdrop pays off the current
    ///         epoch's board, never this. Never reset, so it only ever grows.
    function lifetimePoints(address trader) external view returns (uint256);

    /// @notice The current epoch's top-10 board with scores (unsorted; empty slots
    ///         are address(0) with score 0).
    function currentLeaders() external view returns (address[10] memory board, uint256[10] memory scores);

    /// @notice The top-10 board with scores for ANY epoch (current or past). Boards are
    ///         epoch-keyed and never cleared, so a closed day's final board + frozen
    ///         scores stay readable forever. Unsorted; empty slots are address(0)/0.
    function leadersOf(uint256 epochId) external view returns (address[10] memory board, uint256[10] memory scores);

    // -------------------------------------------------- graduation telemetry

    /// @notice Unique pool-verified holders (pool buys add, emptying removes).
    function holderCount() external view returns (uint32);

    /// @notice Whether `account` is currently included in holderCount.
    function isCountedHolder(address account) external view returns (bool);

    /// @notice Cumulative ETH-equivalent pool volume (wei), priced at the pool spot.
    function volumeEthCum() external view returns (uint256);

    /// @notice A day's closing tick and whether that day traded.
    function dailyTickOf(uint256 dayIndex) external view returns (int24 tick, bool recorded);

    /// @notice Graduation snapshot: holders, volume, mean daily-close tick over the
    ///         last ≤7 non-empty days, and how many days entered the mean.
    function graduationStats()
        external
        view
        returns (uint32 holders, uint256 volumeEth, int24 meanTick, uint16 daysTracked);

    /// @notice This token's deterministic V4 pool id (ETH/token, 1%, spacing 200).
    function POOL_ID() external view returns (bytes32);

    // ------------------------------------------------------------- immutables

    /// @notice The Diggers launchpad: factory, swap router, sole LP, fee harvester.
    function LAUNCHPAD() external view returns (address);

    /// @notice The Uniswap V4 PoolManager this token trades on.
    function POOL_MANAGER() external view returns (address);

    /// @notice Launch timestamp; anchors the 24h anti-whale window (and later the
    ///         graduation windows).
    function DEPLOYED_AT() external view returns (uint64);

    /// @notice ipfs:// URI of the launch metadata JSON (description, image, links).
    ///         Pinned by the frontend before creation; the chain stores only this.
    function metadataURI() external view returns (string memory);
}
