// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

/**
 * @title IDiggers
 * @notice Interface of the Diggers singleton launchpad: factory, V4 unlock-callback
 *         host, swap router, fee harvester, and name registry. This file is
 *         self-contained (no implementation imports) so it can be consumed
 *         standalone.
 * @author BasedDopamine
 */
interface IDiggers {
    // ------------------------------------------------------------------- types

    /// @notice Identity + per-launch fee configuration for a new launch. Charset is
    ///         enforced by the registry; here name/symbol/metadata must be non-empty.
    /// @dev Percentages are ALWAYS 1e18-scaled (1e18 == 100%), never bps.
    struct TokenParams {
        string name;
        string symbol;
        string metadataURI;
        // Creator-chosen LP swap fee, 1e18-scaled. Must be EXACTLY a whole percent in
        // {1,2,3,4,5}e16 (1%–5%, no fractional fees); converted to V4 millionths as
        // `lpFeeWad / 1e12` (10000 / 20000 / 30000 / 40000 / 50000).
        uint256 lpFeeWad;
        // Creator-chosen token-fee burn share, 1e18-scaled, in [0, 1e18]. The airdrop
        // pot share is the remainder (`1e18 - burnShareWad`). Editable post-launch by
        // the token's burn owner (see {setBurnShare}).
        uint256 burnShareWad;
        // Initial holder of BOTH per-token owner roles (fee-split owner + burn owner).
        // A ZERO address means the roles are RENOUNCED from birth: the fee-split table and
        // burn share are frozen forever (fees still flow to the create-time config). To
        // retain control pass your own address; each role can then be transferred or
        // renounced independently (see the ownership functions below).
        address owner;
    }

    /// @notice One create-time distribution slice of the initial buy. Shares are
    ///         1e18-scaled and MUST sum to exactly 1e18 across all orders. `tranches == 0`
    ///         is a plain (unlocked) transfer; otherwise a vesting lock is registered.
    struct LockOrder {
        address to;
        uint256 shareWad;
        uint32 tranches;
        uint64 duration;
    }

    /// @notice On-chain record of a launched token's pool position bounds and fee config.
    ///         The single seeded position is `[tickLower, tickUpper]`, sitting entirely
    ///         BELOW the launch spot (ETH is currency0), so it is 100% token / 0 ETH.
    ///         `tickUpper` is the launch tick (spot at deploy); `tickLower` is the aligned
    ///         floor. `poolFee` is the V4 millionths fee; `burnShareWad` drives the
    ///         token-side harvest split.
    struct TokenRecord {
        address creator;
        bytes32 poolId;
        int24 tickLower;
        int24 tickUpper;
        uint24 poolFee;
        uint128 burnShareWad;
    }

    /// @notice A creator ETH fee-share row (1e18-scaled). The table is set at create and
    ///         can be replaced anytime by the token's fee owner via {setFeeSplits}.
    struct FeeSplit {
        address to;
        uint256 share;
    }

    /// @notice Registry state for one normalized "name object". There is NO name-vs-symbol
    ///         distinction: a token's folded name and folded symbol are both keys in ONE
    ///         shared registry set, and each object carries a single reservation clock.
    /// @dev `reservationUntil` is the one clock: creation is blocked while `now < it`, and
    ///      it only ever advances (1h auto-lock on create, the first-minter 24h graduation
    ///      bonus, and paid `extend`). `firstMinter` is the first token that ever created
    ///      this object — set once, never reset — and is the only token that earns the free
    ///      24h hold on graduation. `contenders` is append-only history for views/UX only.
    struct KeyState {
        uint64 reservationUntil; // the single reservation clock (unix seconds)
        address firstMinter; // first token to ever create this object (0 = never)
        address[] contenders; // every token ever launched on this object (UX/views)
    }

    /// @notice The two registry objects a token holds (its folded name and folded symbol;
    ///         equal when name and symbol normalize to the same string).
    struct TokenKeys {
        bytes32 nameKey;
        bytes32 symbolKey;
    }

    // ----------------------------------------------------------------- events

    /// @notice A new token was deployed, its pool initialized, and liquidity seeded.
    /// @dev Carries the per-token launch config an indexer cannot cheaply derive: identity,
    ///      the deterministic `poolId`, the creator-chosen `poolFee` (client-side quotes),
    ///      and `burnShareWad` (harvest split). Protocol-constant values (start price,
    ///      seeded liquidity, position bounds) are read ONCE from the launchpad, not per log.
    ///      The full creator ETH split rides in `FeeSplitConfigured`; the initial buy (if
    ///      any) rides in the same-tx `Swapped`.
    event Created(
        address indexed token,
        address indexed creator,
        string name,
        string symbol,
        string metadataURI,
        bytes32 poolId,
        uint160 startSqrtPriceX96,
        uint24 poolFee,
        uint128 burnShareWad
    );

    /// @notice The creator ETH fee-split table for a launch, emitted once at create so the
    ///         whole table (recipients + 1e18-scaled shares) is in logs, not just its row
    ///         count. Parallel arrays; `recipients[i]` earns `shares[i]`. Later edits emit
    ///         {FeeSplitUpdated}.
    event FeeSplitConfigured(address indexed token, address[] recipients, uint256[] shares);

    /// @notice The fee owner replaced a token's creator ETH fee-split table. Parallel
    ///         arrays; `recipients[i]` earns `shares[i]` (shares sum to 1e18).
    event FeeSplitUpdated(address indexed token, address[] recipients, uint256[] shares);

    /// @notice The burn owner changed a token's token-side burn share (1e18-scaled); the
    ///         daily traders-airdrop pot takes the remainder (`1e18 - burnShareWad`).
    event BurnShareUpdated(address indexed token, uint256 burnShareWad);

    /// @notice A per-token fee-split owner changed (`newOwner == address(0)` == renounced
    ///         forever: the ETH fee-split table freezes, fees keep flowing).
    event FeeOwnershipTransferred(address indexed token, address indexed previousOwner, address indexed newOwner);

    /// @notice A per-token burn-share owner changed (`newOwner == address(0)` == renounced
    ///         forever: the burn share freezes, fees keep flowing).
    event BurnOwnershipTransferred(address indexed token, address indexed previousOwner, address indexed newOwner);

    /// @notice A creator fee-split slice could not be delivered to its recipient or the
    ///         fee owner and was parked in the token's retry pot; it is re-attempted (added
    ///         to the creator side) on the next harvest.
    event FeeParked(address indexed token, address indexed recipient, uint256 amount);

    /// @notice Router swap settled. Carries post-trade pool state for indexer upserts.
    event Swapped(
        address indexed token,
        address indexed trader,
        bool indexed isBuy,
        uint256 ethAmount,
        uint256 tokenAmount,
        uint160 sqrtPriceAfterX96,
        int24 tickAfter,
        uint128 liquidityAfter,
        uint256 ethInPool,
        uint256 tokenInPool
    );

    /// @notice LP fees collected and split. Carries the full breakdown for indexers.
    /// @dev `ethToPlatform` is the platform-token slice (10% of ETH fees), non-zero only
    ///      while the launch airdrop window is open; afterwards the split is 30/70 and this
    ///      field is 0.
    event Harvested(
        address indexed token,
        address indexed caller,
        uint256 ethTotal,
        uint256 ethToTeam,
        uint256 ethToPlatform,
        uint256 ethToCreators,
        uint256 tokensBurned,
        uint256 tokensToPot
    );

    /// @notice Pull-payment ETH claim settled.
    event Claimed(address indexed account, uint256 amount);

    /// @notice A token was created and now holds both of its registry objects for 1h.
    /// @param launchLockUntil Timestamp both objects stay reserved until (`now + 1h`).
    event Contender(
        bytes32 indexed nameKey, bytes32 indexed symbolKey, address indexed token, uint64 launchLockUntil
    );

    /// @notice A graduated token extended its reservation on both of its objects.
    /// @dev One payment advances BOTH objects' single clocks by the same bought seconds
    ///      (each from its own `max(current, now)` base, so the two `until` values can
    ///      differ). Payments compound — the clock is never reset down.
    event ReservationExtended(
        bytes32 indexed nameKey,
        bytes32 indexed symbolKey,
        address indexed token,
        address payer,
        uint256 ethPaid,
        uint64 nameReservationUntil,
        uint64 symbolReservationUntil
    );

    /// @notice A token graduated (criteria met). Sets its `graduatedAt`; if within its
    ///         first 24h it also freely reserves any object it was the first to mint.
    event Graduated(
        address indexed token,
        bytes32 indexed nameKey,
        bytes32 indexed symbolKey,
        uint32 holders,
        uint256 volumeEthCum,
        uint256 avgMcapEth
    );

    // ---------------------------------------------------------- ownership events

    /// @notice The protocol owner changed (address(0) `newOwner` == renounced forever).
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /// @notice The owner started the one-month airdrop. `start`/`end` bound the window.
    event AirdropStarted(uint64 start, uint64 end);

    /// @notice The owner updated the global team share of ETH fees (1e18-scaled).
    event TeamShareUpdated(uint256 teamShareWad);

    /// @notice The owner rotated the team ETH fee-recipient wallet.
    event FeeRecipientUpdated(address indexed feeRecipient);

    // ------------------------------------------------- token event hub (step 17)

    /// @dev Every non-ERC20 token event is RE-EMITTED here by the launchpad so the whole
    ///      protocol streams from ONE log address — the indexer subscribes to Diggers only
    ///      (plus each token's plain ERC20 Transfer/Approval). Each carries `token` as the
    ///      first indexed topic; the token contract fires them via the guarded `log*`
    ///      callbacks below, so they appear on EVERY pool leg regardless of router.

    /// @notice The primary trade feed for a token pool leg. `epoch` attributes the leg's
    ///         points to the right settlement window; `holdersAfter`/`volumeEthCumAfter`
    ///         snapshot the running graduation stats.
    event PoolTrade(
        address indexed token,
        address indexed trader,
        bool indexed isBuy,
        uint256 tokenAmount,
        uint256 ethValue,
        int24 tick,
        uint32 holdersAfter,
        uint256 volumeEthCumAfter,
        uint256 epoch
    );

    /// @notice Points credited to a trader on a pool leg. `newScore` is the running total
    ///         in `epoch` after the credit; `lifetimeScore` is the trader's all-time total
    ///         across every epoch (never reset, cosmetic). The indexer never reads
    ///         `pointsOf` / `lifetimePoints` — both totals ride the event.
    event PointsCredited(
        address indexed token,
        uint256 indexed epoch,
        address indexed trader,
        bool isBuy,
        uint256 pointsEarned,
        uint256 newScore,
        uint256 lifetimeScore
    );

    /// @notice The top-10 board changed: `entrant` took the minimum slot, evicting
    ///         `evicted` (address(0) when the slot was empty). Emitted only on a real
    ///         membership change so the indexer maintains the exact board from logs.
    event LeaderboardChanged(
        address indexed token, uint256 indexed epoch, address indexed entrant, address evicted, uint256 entrantScore
    );

    /// @notice The unique-holder counter changed — a pool buy counting a new wallet in
    ///         (`added == true`) or any route emptying a counted wallet (p2p, sell, burn;
    ///         `added == false`). Keeps the graduation holders figure exact from logs.
    event HolderCountChanged(address indexed token, address indexed holder, bool added, uint32 holderCountAfter);

    /// @notice A token's epoch closed and its airdrop pot was distributed. `rolledOver`
    ///         (empty slots, sold-out leaders, dust) carries to the next day's pot.
    event EpochSettled(
        address indexed token, uint256 indexed epoch, uint256 potPerWinner, uint256 rolledOver, uint64 nextDeadline
    );

    /// @notice One leaderboard winner received its share of a token's day pot.
    event AirdropPaid(address indexed token, uint256 indexed epoch, address indexed winner, uint256 amount);

    /// @notice A vesting lock was registered on a token for `holder`.
    event LockSet(
        address indexed token, address indexed holder, uint128 total, uint64 start, uint64 duration, uint32 tranches
    );

    // ----------------------------------------------------------------- errors

    /// @notice Token name must be non-empty.
    error NameRequired();

    /// @notice Token symbol must be non-empty.
    error SymbolRequired();

    /// @notice Metadata URI must be non-empty.
    error MetadataRequired();

    /// @notice `lpFeeWad` is not a whole percent in {1,2,3,4,5}e16 (1%–5%, no fractions).
    error LpFeeOutOfRange();

    /// @notice `burnShareWad` exceeds 1e18 (100%).
    error BurnShareInvalid();

    /// @notice Fee-split table is empty-but-nonzero-count, over 10 rows, has a zero
    ///         recipient, or its shares do not sum to exactly 1e18.
    error FeeSplitInvalid();

    /// @notice A lock order is malformed (zero recipient, over 10 orders, tranches>0
    ///         with zero duration) or the shares do not sum to exactly 1e18.
    error LockConfigInvalid();

    /// @notice Distribution locks were supplied without an initial buy (`msg.value`
    ///         did not exceed the creation fee, so nothing was bought for the user).
    error LocksWithoutBuy();

    /// @notice `create` was called with `msg.value` below {CREATION_FEE}.
    error CreationFeeRequired();

    /// @notice CREATE2 of the token's EIP-1167 minimal proxy returned zero.
    error CloneFailed();

    /// @notice Team treasury address must be non-zero.
    error TreasuryRequired();

    /// @notice Platform token address must be non-zero.
    error PlatformTokenRequired();

    /// @notice Owner address must be non-zero (constructor + transfer).
    error OwnerRequired();

    /// @notice Caller is not the current owner.
    error NotOwner();

    /// @notice Caller is not the token's fee-split owner.
    error NotFeeOwner();

    /// @notice Caller is not the token's burn-share owner.
    error NotBurnOwner();

    /// @notice The airdrop has already been started (start is once-only).
    error AirdropAlreadyStarted();

    /// @notice `teamShareWad` is below the 10% floor required while the airdrop is live.
    error TeamShareTooLow();

    /// @notice `teamShareWad` exceeds 1e18 (100%).
    error TeamShareTooHigh();

    /// @notice The pool for this token was already initialized.
    error PoolAlreadyInitialized();

    /// @notice Seeding did not consume the full fixed supply.
    error SeedIncomplete(uint256 expected, uint256 used);

    /// @notice Address is not a token deployed through this launchpad.
    error UnknownToken();

    /// @notice Buy was called without sending ETH.
    error ZeroEth();

    /// @notice No ETH credit to claim.
    error NothingToClaim();

    /// @notice ETH transfer to claimant failed.
    error EthTransferFailed();

    /// @notice A reentrant call into a guarded ETH-sending path was blocked.
    error Reentrancy();

    /// @notice The name object is reserved right now (its reservation clock is live).
    error NameReserved();

    /// @notice The symbol object is reserved right now (its reservation clock is live).
    error SymbolReserved();

    /// @notice This token already graduated.
    error AlreadyGraduated();

    /// @notice Only a graduated token that still passes all three criteria may extend.
    error NotGraduated();

    /// @notice Reservation would exceed the 100-year cap.
    error TooLong();

    /// @notice Reservation payment too small to buy any time (or zero).
    error ZeroReservation();

    /// @notice The token does not meet all three graduation criteria yet.
    error CriteriaNotMet();

    /// @dev Slippage() and ZeroSwapAmount() are inherited from DiggerV4Base.

    // ------------------------------------------------------------- immutables

    /// @notice Launch sqrt price for every pool (Q64.96). Chosen for a pump.fun-like
    ///         starting market cap (~1.33 ETH for 1e9 supply).
    function START_SQRT_PRICE_X96() external view returns (uint160);

    /// @notice Spacing-aligned launch tick matching the fixed launch start price.
    function START_TICK() external view returns (int24);

    /// @notice The platform coin — receives the windowed 10% ETH fee slice.
    function PLATFORM_TOKEN() external view returns (address);

    /// @notice The shared DiggersToken implementation every launch is cloned from
    ///         (EIP-1167 minimal proxies; deployed once by the launchpad constructor,
    ///         no admin, no upgrade path).
    function TOKEN_IMPLEMENTATION() external view returns (address);

    /// @dev POOL_MANAGER() is inherited from DiggerV4Base (immutable getter).

    // ------------------------------------------------------------- ownership

    /// @notice The protocol owner (address(0) once renounced).
    function owner() external view returns (address);

    /// @notice The team ETH fee-recipient wallet (owner-editable).
    function feeRecipient() external view returns (address);

    /// @notice The global team share of ETH fees (1e18-scaled; creator = 1e18 - this).
    function teamShareWad() external view returns (uint256);

    /// @notice Airdrop window start (seconds); 0 until the owner starts it.
    function airdropStart() external view returns (uint64);

    /// @notice Airdrop window end (seconds); `airdropStart + 30 days` once started.
    function airdropEnd() external view returns (uint64);

    /// @notice Whether the airdrop window is currently open.
    function airdropActive() external view returns (bool);

    /// @notice Start the one-month airdrop (owner-only, once). Requires `teamShareWad`
    ///         to already meet the 10% floor.
    function startAirdrop() external;

    /// @notice Set the global team share of ETH fees (owner-only). Must be <= 1e18, and
    ///         >= 1e17 while the airdrop is live (that 10% funds the coin LP).
    function setTeamShareWad(uint256 newTeamShareWad) external;

    /// @notice Rotate the team ETH fee-recipient wallet (owner-only). Already-owed
    ///         balances stay claimable by the previous wallet.
    function setFeeRecipient(address newFeeRecipient) external;

    /// @notice Transfer ownership to a new non-zero address (owner-only).
    function transferOwnership(address newOwner) external;

    /// @notice Renounce ownership forever — every owner function is then locked and the
    ///         current config (split, wallets, airdrop window) freezes (owner-only).
    function renounceOwnership() external;

    // -------------------------------------------------------------- create

    /**
     * @notice Flat creation fee in wei, REQUIRED on every `create`. It is not kept by
     *         anyone: the slice runs a real pool buy whose output is burned, so every
     *         pool's first Swap lands in its creation block (external indexers list
     *         pairs on first trade).
     */
    function CREATION_FEE() external view returns (uint256);

    /**
     * @notice Deploy a token, initialize its V4 pool, and seed the entire supply as
     *         single-sided token liquidity in one transaction. Convenience overload: no
     *         custom fee-split table and no distribution locks. `msg.value` must cover
     *         {CREATION_FEE} (burned fee buy); the remainder runs an atomic initial buy
     *         routed to the creator (slippage floor 0).
     * @param params Identity + LP fee + burn-share config (see {TokenParams}).
     * @return token Address of the new DiggersToken.
     */
    function create(TokenParams calldata params) external payable returns (address token);

    /**
     * @notice Full launch: deploy + seed, optionally set the creator fee-split table, run
     *         an atomic initial buy with `msg.value`, and distribute the purchased tokens
     *         across recipients with optional vesting locks — all in one transaction.
     * @dev Percentages are ALWAYS 1e18-scaled. `msg.value` must cover {CREATION_FEE}
     *      (burned fee buy); the REMAINDER is the user's initial buy. `feeSplits` empty
     *      ⇒ `[{creator, 1e18}]`. `locks` empty ⇒ the initial buy goes to the creator
     *      (real pool leg: points + volume + holder count, 2% first-day cap applies).
     *      `locks` non-empty ⇒ the buy is aggregated on the launchpad then split per
     *      `shareWad` (sum 1e18) to ≤10 recipients; `tranches > 0` registers a vesting
     *      lock. Supplying `locks` with no remainder reverts {LocksWithoutBuy}.
     * @param params Identity + LP fee + burn-share config (see {TokenParams}).
     * @param feeSplits Creator ETH fee-share table (≤10 rows, shares sum 1e18); editable
     *        post-launch by the fee owner via {setFeeSplits}.
     * @param locks Distribution + vesting orders for the initial buy (≤10, shares sum 1e18).
     * @param initialBuyMinOut Minimum tokens the initial buy must return (slippage floor).
     * @return token Address of the new DiggersToken.
     */
    function create(
        TokenParams calldata params,
        FeeSplit[] calldata feeSplits,
        LockOrder[] calldata locks,
        uint256 initialBuyMinOut
    ) external payable returns (address token);

    // -------------------------------------------------------------- router

    /**
     * @notice Buy tokens with exact ETH. Output goes directly from the PoolManager
     *         to `to` (defaults to `msg.sender` when zero).
     * @param token Launched DiggersToken.
     * @param minOut Minimum tokens out (mandatory slippage floor).
     * @param to Recipient; address(0) means `msg.sender`.
     */
    function buy(address token, uint256 minOut, address to) external payable;

    /**
     * @notice Sell tokens for ETH. No approve needed — pulls directly from the caller
     *         to the PoolManager via the silent router exemption.
     * @param token Launched DiggersToken.
     * @param amountIn Tokens to sell (18 dec).
     * @param minOut Minimum ETH out (wei).
     * @param to ETH recipient; address(0) means `msg.sender`.
     */
    function sell(address token, uint256 amountIn, uint256 minOut, address to) external;

    /**
     * @notice Split the CALLER's own tokens across ≤10 recipients, optionally vesting each,
     *         in one transaction — the post-launch equivalent of the create-time
     *         distribution locks.
     * @dev Pulls `amount` from `msg.sender` approve-free (the launchpad only ever pulls
     *      `from == msg.sender` of the outer call — the same trust boundary as {sell}) and
     *      distributes it per `locks`: `shareWad` sums to exactly 1e18, the last row absorbs
     *      rounding dust, and `tranches > 0` registers a vesting lock (competing for the
     *      token's global 10-locker budget; a second lock on the same address reverts).
     *      Pure p2p — no pool leg, so no points/volume/holder credit. The 2% first-day cap
     *      applies per recipient. Reverts {ZeroSwapAmount} on zero `amount` and
     *      {LockConfigInvalid} on an empty or malformed table.
     * @param token Launched DiggersToken.
     * @param amount Tokens to pull from the caller (18 dec).
     * @param locks Distribution + vesting orders (1..10, shares sum 1e18).
     */
    function transferAndLock(address token, uint256 amount, LockOrder[] calldata locks) external;

    /**
     * @notice Buy with exact ETH, then split the purchased tokens across ≤10 recipients,
     *         optionally vesting each — the post-launch equivalent of a create-time locked
     *         initial buy.
     * @dev `msg.value` runs a real swap with the launchpad as recipient (cap- and
     *      points-exempt aggregation), emitting the rich {Swapped}/{PoolTrade}, then the
     *      output is distributed per `locks` (same rules as {transferAndLock}). Reverts
     *      {ZeroEth} on zero value and {LockConfigInvalid} on an empty or malformed table.
     * @param token Launched DiggersToken.
     * @param minOut Minimum tokens the buy must return (mandatory slippage floor).
     * @param locks Distribution + vesting orders (1..10, shares sum 1e18).
     */
    function buyAndLock(address token, uint256 minOut, LockOrder[] calldata locks) external payable;

    /// @notice Quote tokens out for an exact ETH input (fee-inclusive, view-only).
    function quoteBuy(address token, uint256 ethIn) external view returns (uint256 amountOut);

    /// @notice Quote ETH out for an exact token input (fee-inclusive, view-only).
    function quoteSell(address token, uint256 amountIn) external view returns (uint256 amountOut);

    // ------------------------------------------------------------- fees

    /// @notice Collect accrued LP fees and split per protocol rules (pull credits).
    function harvest(address token) external;

    /// @notice Withdraw accumulated ETH fee credits.
    function claim() external;

    /// @notice Pull-payment ETH credits (wei) for `account`.
    function ethOwed(address account) external view returns (uint256);

    /// @notice Creator fee-split table size for a launched token.
    function feeSplitCount(address token) external view returns (uint8);

    /// @notice One row of the creator fee-split table.
    function feeSplitAt(address token, uint256 index) external view returns (FeeSplit memory);

    /// @notice Creator ETH fee slices that failed delivery and await the next harvest
    ///         (wei), per token.
    function pendingEth(address token) external view returns (uint256);

    // ---------------------------------------------------- per-token ownership

    /// @notice The token's fee-split owner (may edit the ETH creator fee table). Zero once
    ///         renounced — the table is then frozen forever.
    function feeOwner(address token) external view returns (address);

    /// @notice The token's burn-share owner (may edit the burn/airdrop split). Zero once
    ///         renounced — the burn share is then frozen forever.
    function burnOwner(address token) external view returns (address);

    /**
     * @notice Replace a token's creator ETH fee-split table (fee owner only).
     * @dev The new list must be 1..10 rows, every recipient non-zero, and shares sum to
     *      exactly 1e18. Fully replaces the previous table; takes effect from the next
     *      harvest. This is the ONLY thing the fee owner may change.
     * @param token The launched token.
     * @param rows The new fee-split rows.
     */
    function setFeeSplits(address token, FeeSplit[] calldata rows) external;

    /**
     * @notice Update a token's token-side burn share (burn owner only).
     * @dev `burnShareWad` is 1e18-scaled and must be <= 1e18; the daily traders-airdrop
     *      pot receives the remainder. Takes effect from the next harvest. This is the
     *      ONLY thing the burn owner may change.
     * @param token The launched token.
     * @param burnShareWad New burn share (1e18-scaled, <= 1e18).
     */
    function setBurnShare(address token, uint256 burnShareWad) external;

    /// @notice Transfer a token's fee-split ownership to a new non-zero address (fee owner
    ///         only).
    function transferFeeOwnership(address token, address newOwner) external;

    /// @notice Renounce a token's fee-split ownership forever — the ETH fee table freezes
    ///         at its current config and fees keep flowing (fee owner only).
    function renounceFeeOwnership(address token) external;

    /// @notice Transfer a token's burn-share ownership to a new non-zero address (burn
    ///         owner only).
    function transferBurnOwnership(address token, address newOwner) external;

    /// @notice Renounce a token's burn-share ownership forever — the burn share freezes at
    ///         its current value and fees keep flowing (burn owner only).
    function renounceBurnOwnership(address token) external;

    // -------------------------------------------------------------- registry

    /**
     * @notice Extend the reservation on both of a graduated token's objects.
     * @dev Anyone may pay, but `token` MUST be graduated AND still pass all three
     *      criteria right now (else `NotGraduated`). `1 ETH = 365 days` linear; each
     *      object's clock advances `max(current, now) + bought` (payments compound; the
     *      clock is never reset down), capped at `now + 100y` (`TooLong`). One payment
     *      covers both objects. Proceeds credit the team via the pull ledger. No refunds.
     * @param token The graduated token to reserve for.
     */
    function extendReservation(address token) external payable;

    /// @notice Whether a name could be created right now (its object's clock has lapsed).
    function isNameFree(string calldata name) external view returns (bool);

    /// @notice Whether a symbol could be created right now (its object's clock has lapsed).
    function isSymbolFree(string calldata symbol) external view returns (bool);

    /// @notice Registry state for a name object and a symbol object (same shared set).
    function keyStateOf(string calldata name, string calldata symbol)
        external
        view
        returns (KeyState memory nameState, KeyState memory symbolState);

    /// @notice The two registry objects `token` holds (folded name + folded symbol).
    function tokenKeys(address token) external view returns (TokenKeys memory);

    /// @notice When `token` graduated (unix seconds); 0 if it never has.
    function graduatedAt(address token) external view returns (uint64);

    // ------------------------------------------------------------ graduation

    /**
     * @notice Graduate a token once it meets the three criteria. Permissionless, callable
     *         anytime (no claim window). Sets `graduatedAt`; if the token is still in its
     *         first 24h it also freely reserves any object it was the first to mint.
     * @dev Usually unnecessary to call: the protocol auto-graduates a first-minter token
     *      on its next `buy`/`sell` within its first 24h. This is the explicit path for
     *      tokens that cross the line afterwards. Reverts `CriteriaNotMet` if short,
     *      `AlreadyGraduated` if already done.
     * @param token The token to graduate.
     */
    function graduate(address token) external;

    /**
     * @notice Read-only graduation progress for UI progress bars.
     * @param token The token to inspect.
     * @return holders Current unique pool-verified holders.
     * @return volumeEth Cumulative ETH-equivalent volume (wei).
     * @return avgMcapEth ≤7-day mean-tick market cap (wei).
     * @return freeWindowEndsAt End of the token's free 24h window (unix seconds).
     * @return reservedUntil Reservation clock covering both objects (min of the two).
     * @return passes The three criteria flags [holders, volume, mcap].
     */
    function graduationProgress(address token)
        external
        view
        returns (
            uint32 holders,
            uint256 volumeEth,
            uint256 avgMcapEth,
            uint64 freeWindowEndsAt,
            uint64 reservedUntil,
            bool[3] memory passes
        );

    // ------------------------------------------------------------------ views

    /// @notice Whether `token` was launched through this contract.
    function isDiggersToken(address token) external view returns (bool);

    /// @notice Pool record for a launched token.
    function tokenRecord(address token) external view returns (TokenRecord memory);

    /// @notice Monotonic nonce used in CREATE2 salts (creator, symbol, nonce).
    function createNonce() external view returns (uint256);

    /// @notice The V4 PoolManager this launchpad routes every pool through.
    function poolManager() external view returns (address);

    /**
     * @notice Live pool snapshot for indexer reconciliation (NOT a per-pageview read —
     *         the UI derives price/depth from the `Swapped`/`Created` log stream). Prefer
     *         events; use this only to periodically reconcile cached state against chain.
     * @param token Launched DiggersToken.
     * @return sqrtPriceX96 Current pool sqrt price (Q64.96).
     * @return tick Current pool tick.
     * @return liquidity Active liquidity of the single seeded position.
     * @return ethInPool Virtual ETH reserve of the position at spot (wei).
     * @return tokenInPool Virtual token reserve of the position at spot.
     */
    function poolState(address token)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint128 liquidity, uint256 ethInPool, uint256 tokenInPool);

    /**
     * @notice Exact uncollected LP fees awaiting the next harvest, for indexer
     *         reconciliation of the harvestable/airdrop pot. Post-harvest ETH credits
     *         are already in the `Harvested` event and `ethOwed`.
     * @param token Launched DiggersToken.
     * @return ethFees Uncollected ETH-side fees (wei).
     * @return tokenFees Uncollected token-side fees.
     */
    function pendingFees(address token) external view returns (uint256 ethFees, uint256 tokenFees);

    // ------------------------------------------------ token event hub callbacks

    /// @dev The following `log*` functions are the token event hub: a DiggersToken calls
    ///      them from its `_update`/settlement/lock paths so the launchpad re-emits the
    ///      event with `token == msg.sender`. Each reverts {UnknownToken} unless the
    ///      caller is a token launched here, so no third party can forge protocol events.
    ///      They mutate no state — logs only.

    /// @notice Emit {PoolTrade} for the calling token's pool leg.
    function logPoolTrade(
        address trader,
        bool isBuy,
        uint256 tokenAmount,
        uint256 ethValue,
        int24 tick,
        uint32 holdersAfter,
        uint256 volumeEthCumAfter,
        uint256 epoch
    ) external;

    /// @notice Emit {PointsCredited} for the calling token.
    function logPoints(
        uint256 epoch,
        address trader,
        bool isBuy,
        uint256 pointsEarned,
        uint256 newScore,
        uint256 lifetimeScore
    ) external;

    /// @notice Emit {LeaderboardChanged} for the calling token.
    function logLeaderboard(uint256 epoch, address entrant, address evicted, uint256 entrantScore) external;

    /// @notice Emit {HolderCountChanged} for the calling token.
    function logHolderCount(address holder, bool added, uint32 holderCountAfter) external;

    /// @notice Emit {EpochSettled} for the calling token.
    function logEpochSettled(uint256 epoch, uint256 potPerWinner, uint256 rolledOver, uint64 nextDeadline) external;

    /// @notice Emit {AirdropPaid} for the calling token.
    function logAirdropPaid(uint256 epoch, address winner, uint256 amount) external;

    /// @notice Emit {LockSet} for the calling token.
    function logLockSet(address holder, uint128 total, uint64 start, uint64 duration, uint32 tranches) external;
}
