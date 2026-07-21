// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

/**
 * @title Diggers
 * @notice Singleton launchpad: deploys DiggersToken instances, owns every V4
 *         liquidity position, and hosts the unlock-callback router surface. Step 9
 *         covers create + pool seed; swap routing lands in step 10; fee harvest and
 *         the name registry land in later steps.
 * @author BasedDopamine
 */
import {DiggerV4, DiggerV4Base, IPoolManagerLite} from "./libs/DiggerV4.sol";
import {DiggerMath} from "./libs/DiggerMath.sol";
import {DiggerSwapViews} from "./libs/DiggerSwapViews.sol";
import {DiggerQuotes} from "./libs/DiggerQuotes.sol";
import {DiggerHarvestViews} from "./libs/DiggerHarvestViews.sol";
import {DiggerHarvestLib} from "./libs/DiggerHarvestLib.sol";
import {DiggerCreateLib} from "./libs/DiggerCreateLib.sol";
import {DiggerRegistryLib} from "./libs/DiggerRegistryLib.sol";
import {DiggerGraduationLib} from "./libs/DiggerGraduationLib.sol";
import {DiggersToken} from "./DiggersToken.sol";
import {IDiggers} from "./interfaces/IDiggers.sol";

contract Diggers is DiggerV4Base, IDiggers {
    // -------------------------------------------------- constants / immutables

    /// @dev Tick spacing of every Diggers pool. Must match DiggersToken.POOL_TICK_SPACING.
    ///      The LP fee is per-token (creator-chosen 1%–5%, stored in each TokenRecord).
    int24 private constant POOL_TICK_SPACING = 200;

    /// @dev 1e18 == 100%. Percentages are ALWAYS 1e18-scaled, never bps.
    uint256 private constant WAD = 1e18;

    /// @dev Hard cap on distribution/vesting orders per launch (matches the token's
    ///      MAX_LOCKERS so create-time locks can never overflow it).
    uint256 private constant MAX_LOCKS = 10;

    /// @dev EIP-1153 transient slot for approve-free sell settlement. While set,
    ///      `_transferToken` pulls from this address via `transferFrom` straight to
    ///      the PoolManager instead of spending the launchpad's own balance.
    bytes32 private constant SELL_PAYER_SLOT = keccak256("diggers.router.sellPayer");

    /// @dev EIP-1153 transient reentrancy latch for the ETH-sending path (`claim`).
    ///      Defense-in-depth: the pull ledger is already CEI-safe (balance zeroed before
    ///      the call), this simply hard-blocks any nested re-entry. Auto-clears at tx end.
    bytes32 private constant REENTRANCY_SLOT = keccak256("diggers.reentrancy.lock");

    /// @dev Opportunistic harvest when pending ETH fees reach this floor (wei).
    uint256 private constant HARVEST_THRESHOLD_ETH = 1e15;

    /// @dev Opportunistic harvest when pending token fees reach this floor (18 dec).
    uint256 private constant HARVEST_THRESHOLD_TOKEN = 1e18;

    /// @notice Flat creation fee, REQUIRED on every `create` (wei). Not kept by anyone:
    ///         it runs a real pool buy (recipient = launchpad, cap/points-exempt) whose
    ///         output is burned — so every pool's first PoolManager `Swap` lands in its
    ///         creation block and trade-triggered indexers list the pair immediately.
    uint256 public constant CREATION_FEE = 0.00001 ether;

    /// @notice Spacing-aligned launch tick. Passed at deploy so create() never pays an
    ///         on-chain tick search (~1.33 ETH FDV at tick-derived sqrt).
    int24 public immutable START_TICK;

    /// @notice The platform coin. Receives the windowed 10% ETH fee slice via the pull
    ///         ledger; `DiggersCoin.finalize` claims it. Passed into every launched token
    ///         so its buy-leg mint hook can call `creditBuy`.
    address public immutable PLATFORM_TOKEN;

    /// @notice The shared DiggersToken implementation, deployed once by this constructor.
    ///         Every launch is an EIP-1167 minimal proxy of it (never upgradeable — the
    ///         implementation has no admin and a clone's target is fixed in its bytecode).
    address public immutable TOKEN_IMPLEMENTATION;

    /// @dev Default team share of ETH fees at deploy: 30% (owner-editable afterwards).
    uint256 private constant DEFAULT_TEAM_SHARE_WAD = 3e17;

    /// @dev Fixed platform slice carved from the team side while the airdrop is live: 10%.
    ///      `teamShareWad` must stay >= this whenever the window is open.
    uint256 private constant PLATFORM_SLICE_WAD = 1e17;

    /// @dev Airdrop window length once the owner starts it (seconds).
    uint256 private constant AIRDROP_DURATION = 30 days;

    // ---------------------------------------------------------------- storage

    /// @notice Protocol owner. Can start the airdrop, edit the team/creator split, rotate
    ///         the fee recipient and the owner, and renounce (owner == 0 freezes it all).
    address public owner;

    /// @notice Team treasury — receives its ETH fee share via the pull ledger. Mutable so
    ///         the owner can rotate the wallet; already-owed balances stay with the old one.
    address public feeRecipient;

    /// @notice Team share of collected ETH fees (1e18-scaled). Creator side is the
    ///         remainder (1e18 - teamShareWad). While the airdrop is live a fixed 10% is
    ///         carved out of this team side and routed to the platform coin.
    uint256 public teamShareWad;

    /// @notice Airdrop window start (seconds); 0 until the owner calls `startAirdrop`.
    uint64 public airdropStart;

    /// @notice Airdrop window end (seconds); `airdropStart + 30 days` once started.
    uint64 public airdropEnd;

    /// @dev Monotonic CREATE2 salt nonce.
    uint256 private _createNonce;

    /// @dev Whether an address is a token launched here.
    mapping(address => bool) public isDiggersToken;

    /// @dev Per-token pool metadata for views and later router/fee paths.
    mapping(address => TokenRecord) private _tokenRecords;

    /// @dev Pull-payment ETH credits (wei) accrued from harvests.
    mapping(address => uint256) public ethOwed;

    /// @dev Creator fee-split row count per token (fee-owner editable via setFeeSplits).
    mapping(address => uint8) private _feeSplitCount;

    /// @dev Creator fee-split table per token (fee-owner editable via setFeeSplits).
    mapping(address => mapping(uint256 => FeeSplit)) private _feeSplits;

    /// @notice Per-token fee-split owner — may replace the ETH creator fee table. Zero once
    ///         renounced (table frozen). Initialized at create from `TokenParams.owner`.
    mapping(address => address) public feeOwner;

    /// @notice Per-token burn-share owner — may edit the burn/airdrop split. Zero once
    ///         renounced (burn share frozen). Initialized at create from `TokenParams.owner`.
    mapping(address => address) public burnOwner;

    /// @notice Creator ETH fee slices that failed delivery, parked per token (wei). Folded
    ///         into the creator side of the next harvest and re-attempted (never re-taxed).
    mapping(address => uint256) public pendingEth;

    /// @dev The one shared name-object registry. A token's folded name and folded symbol
    ///      are both keys here; each object carries a single reservation clock. There is
    ///      no name-vs-symbol distinction.
    mapping(bytes32 => KeyState) private _registry;

    /// @dev Per-token graduation timestamp (unix seconds; 0 = never graduated).
    mapping(address => uint64) private _graduatedAt;

    /// @dev The two registry objects each token holds (folded name + folded symbol).
    mapping(address => TokenKeys) private _tokenKeys;

    // ------------------------------------------------------------ constructor

    /**
     * @notice Binds the PoolManager and treasury, pins the launch price, and wires in the
     *         platform coin (reading the shared airdrop-window end from it).
     * @param poolManager_ Canonical V4 PoolManager on Robinhood Chain (immutable).
     * @param feeRecipient_ Initial pull-payment recipient for the team's ETH fee slice.
     * @param startTick Spacing-aligned launch tick (off-chain derived from start price).
     * @param platformToken The DiggersCoin platform token (deployed first; `init` wires it
     *        back to this launchpad once this contract's address is known).
     * @param owner_ Initial protocol owner (airdrop start + config + wallet rotation).
     */
    constructor(
        address poolManager_,
        address feeRecipient_,
        int24 startTick,
        address platformToken,
        address owner_
    ) DiggerV4Base(poolManager_) {
        if (feeRecipient_ == address(0)) revert TreasuryRequired();
        if (platformToken == address(0)) revert PlatformTokenRequired();
        if (owner_ == address(0)) revert OwnerRequired();
        feeRecipient = feeRecipient_;
        START_TICK = startTick;
        PLATFORM_TOKEN = platformToken;
        owner = owner_;
        teamShareWad = DEFAULT_TEAM_SHARE_WAD;

        // The one full DiggersToken deploy in the system's lifetime. LAUNCHPAD baked
        // into it is msg.sender == this launchpad; every create() clones this address.
        TOKEN_IMPLEMENTATION = address(new DiggersToken(poolManager_, platformToken));

        // Platform brand guard: permanently block the name "Diggers" and symbol "DIG"
        // (the platform coin's identity) from ever being launched here. Irreversible.
        DiggerRegistryLib.reserveForever(_registry, "Diggers", "DIG");
    }

    // ------------------------------------------------------------ ownership

    /// @dev Restricts a call to the current owner (reverts once renounced).
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @dev Restricts a call to the token's fee-split owner (reverts once renounced).
    modifier onlyFeeOwner(address token) {
        if (msg.sender != feeOwner[token]) revert NotFeeOwner();
        _;
    }

    /// @dev Restricts a call to the token's burn-share owner (reverts once renounced).
    modifier onlyBurnOwner(address token) {
        if (msg.sender != burnOwner[token]) revert NotBurnOwner();
        _;
    }

    /// @dev Transient reentrancy latch. Redundant with the CEI pull ledger, kept as an
    ///      explicit guard on the ETH-sending path.
    modifier nonReentrant() {
        bytes32 slot = REENTRANCY_SLOT;
        assembly {
            if tload(slot) {
                mstore(0x00, 0xab143c06) // Reentrancy()
                revert(0x1c, 0x04)
            }
            tstore(slot, 1)
        }
        _;
        assembly {
            tstore(slot, 0)
        }
    }

    /// @notice Whether the airdrop window is currently open.
    function airdropActive() public view returns (bool) {
        return airdropStart != 0 && block.timestamp < airdropEnd;
    }

    /// @notice Start the one-month airdrop (owner-only, once, irreversible). Requires
    ///         `teamShareWad` to already meet the 10% floor.
    function startAirdrop() external onlyOwner {
        if (airdropStart != 0) revert AirdropAlreadyStarted();
        if (teamShareWad < PLATFORM_SLICE_WAD) revert TeamShareTooLow();
        uint64 start = uint64(block.timestamp);
        uint64 end = uint64(block.timestamp + AIRDROP_DURATION);
        airdropStart = start;
        airdropEnd = end;
        emit AirdropStarted(start, end);
    }

    /// @notice Set the global team share of ETH fees (owner-only). Must be ≤ 1e18 (100%),
    ///         and ≥ 1e17 (10%) while the airdrop is live (that 10% funds the coin LP).
    function setTeamShareWad(uint256 newTeamShareWad) external onlyOwner {
        if (newTeamShareWad > WAD) revert TeamShareTooHigh();
        // While the airdrop is live the team side funds the 10% LP slice, so it may not
        // drop below it. Outside the window the owner may set any 0..100% split.
        if (airdropActive() && newTeamShareWad < PLATFORM_SLICE_WAD) revert TeamShareTooLow();
        teamShareWad = newTeamShareWad;
        emit TeamShareUpdated(newTeamShareWad);
    }

    /// @notice Rotate the team ETH fee-recipient wallet (owner-only). Already-owed
    ///         balances stay claimable by the previous wallet.
    function setFeeRecipient(address newFeeRecipient) external onlyOwner {
        if (newFeeRecipient == address(0)) revert TreasuryRequired();
        feeRecipient = newFeeRecipient;
        emit FeeRecipientUpdated(newFeeRecipient);
    }

    /// @notice Transfer protocol ownership to a new non-zero address (owner-only).
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert OwnerRequired();
        address prev = owner;
        owner = newOwner;
        emit OwnershipTransferred(prev, newOwner);
    }

    /// @notice Renounce ownership forever — every owner function is then locked and the
    ///         current config (split, wallets, airdrop window) freezes.
    function renounceOwnership() external onlyOwner {
        address prev = owner;
        owner = address(0);
        emit OwnershipTransferred(prev, address(0));
    }

    // ------------------------------------------------------------- receive

    /// @dev Accepts ETH for V4 settlement during unlock rounds (swaps land in step 10).
    receive() external payable {}

    // -------------------------------------------------------------- create

    /// @notice Deploy a token, initialize its V4 pool, and seed the entire supply as
    ///         single-sided token liquidity in one transaction. Convenience overload: no
    ///         custom fee-split table and no distribution locks. `msg.value` must cover
    ///         `CREATION_FEE`; the remainder runs an atomic initial buy routed to the
    ///         creator (slippage floor 0).
    /// @param params Identity + LP fee + burn-share config (see `TokenParams`).
    /// @return token Address of the new DiggersToken.
    function create(TokenParams calldata params) external payable returns (address token) {
        FeeSplit[] memory noSplits = new FeeSplit[](0);
        LockOrder[] memory noLocks = new LockOrder[](0);
        return _create(params, noSplits, noLocks, 0);
    }

    /// @notice Full launch: deploy + seed, optionally set the creator fee-split table, run
    ///         an atomic initial buy with `msg.value`, and distribute the purchased tokens
    ///         across recipients with optional vesting locks — all in one transaction.
    /// @param params Identity + LP fee + burn-share config (see `TokenParams`).
    /// @param feeSplits Creator ETH fee-share table (≤10 rows, shares sum 1e18).
    /// @param locks Distribution + vesting orders for the initial buy (≤10, shares sum 1e18).
    /// @param initialBuyMinOut Minimum tokens the initial buy must return (slippage floor).
    /// @return token Address of the new DiggersToken.
    function create(
        TokenParams calldata params,
        FeeSplit[] calldata feeSplits,
        LockOrder[] calldata locks,
        uint256 initialBuyMinOut
    ) external payable returns (address token) {
        // Copy the calldata tables into memory for the shared path (the create library
        // takes memory, and distribution reads the orders back here in Diggers' context).
        FeeSplit[] memory feeSplitsMem = feeSplits;
        LockOrder[] memory locksMem = locks;
        return _create(params, feeSplitsMem, locksMem, initialBuyMinOut);
    }

    /// @dev Shared launch path. Deploy (EIP-1167 clone of TOKEN_IMPLEMENTATION) / seed /
    ///      config live in `DiggerCreateLib` via delegatecall; the atomic initial buy +
    ///      distribution run here so they reuse the internal swap router, slippage
    ///      guard, and the token's approve-free move + lock registration.
    function _create(
        TokenParams calldata params,
        FeeSplit[] memory feeSplits,
        LockOrder[] memory locks,
        uint256 initialBuyMinOut
    ) private returns (address token) {
        // Registry gate (both objects) BEFORE any deploy — reverts roll back the CREATE2.
        (bytes32 nameKey, bytes32 symbolKey) =
            DiggerRegistryLib.precheck(_registry, params.name, params.symbol);

        uint256 nonce = _createNonce;
        unchecked {
            ++_createNonce;
        }
        token = DiggerCreateLib.create(
            isDiggersToken,
            _tokenRecords,
            _feeSplitCount,
            _feeSplits,
            POOL_MANAGER,
            START_TICK,
            nonce,
            params,
            feeSplits,
            TOKEN_IMPLEMENTATION
        );

        // Record the token on both objects and (re)arm their 1h creation lock.
        DiggerRegistryLib.appendContender(_registry, _tokenKeys, token, nameKey, symbolKey);

        // Seat both per-token owner roles directly from the param. A ZERO owner means the
        // roles are RENOUNCED from birth — the fee-split table and burn share are frozen
        // forever (fees still flow to the create-time config). To retain control the caller
        // passes its own address. Skip the writes/events when renounced (mappings default 0).
        address tokenOwner = params.owner;
        if (tokenOwner != address(0)) {
            feeOwner[token] = tokenOwner;
            burnOwner[token] = tokenOwner;
            emit FeeOwnershipTransferred(token, address(0), tokenOwner);
            emit BurnOwnershipTransferred(token, address(0), tokenOwner);
        }

        // Mandatory creation-fee buy: 0.00001 ETH runs a REAL pool leg bought to the
        // launchpad (cap/points-exempt) and the output is burned. Every pool therefore
        // has its first PoolManager Swap in its creation block — external indexers that
        // list pairs on first trade (GMGN etc.) pick the token up immediately.
        if (msg.value < CREATION_FEE) revert CreationFeeRequired();
        DiggerV4.SwapOutcome memory feeOut = _swapV4(_poolKey(token), true, CREATION_FEE, address(this), 0);
        _emitSwapped(token, msg.sender, true, feeOut.amountIn, feeOut.amountOut);
        DiggersToken(token).burn(feeOut.amountOut);

        uint256 buyValue = msg.value - CREATION_FEE;
        if (buyValue > 0) {
            _initialBuy(token, locks, initialBuyMinOut, buyValue);
        } else if (locks.length != 0) {
            // Nothing was bought for the user, so there is nothing to distribute or lock.
            revert LocksWithoutBuy();
        }
    }

    /// @dev Atomic create-time buy of `amount` ETH (msg.value minus the creation fee).
    ///      With no distribution locks the output goes straight to the creator (a real
    ///      pool leg: points, volume, holder count, and the 2% first-day cap all apply).
    ///      With locks the launchpad aggregates the purchase (it is cap- and points-
    ///      exempt) then splits it in {_distribute}.
    function _initialBuy(address token, LockOrder[] memory locks, uint256 minOut, uint256 amount) private {
        bool split = locks.length > 0;
        if (split) _validateLocks(locks);
        address recipient = split ? address(this) : msg.sender;

        DiggerV4.SwapOutcome memory out = _swapV4(_poolKey(token), true, amount, recipient, minOut);
        _emitSwapped(token, msg.sender, true, out.amountIn, out.amountOut);

        if (split) _distribute(token, out.amountOut, locks);
    }

    /// @dev Shared validation for every LockOrder table (create initial buy, transferAndLock,
    ///      buyAndLock): 1..10 rows, no zero recipient, `tranches > 0` needs a duration, and
    ///      shares sum to exactly 1e18. Empty tables revert (there is nothing to distribute).
    function _validateLocks(LockOrder[] memory locks) private pure {
        uint256 n = locks.length;
        if (n == 0 || n > MAX_LOCKS) revert LockConfigInvalid();

        uint256 sum;
        for (uint256 i; i < n; ++i) {
            LockOrder memory lo = locks[i];
            if (lo.to == address(0)) revert LockConfigInvalid();
            if (lo.tranches > 0 && lo.duration == 0) revert LockConfigInvalid();
            sum += lo.shareWad;
        }
        if (sum != WAD) revert LockConfigInvalid();
    }

    /// @dev Splits `purchased` tokens (held by the launchpad) across the ≤10 recipients by
    ///      1e18-scaled share; the last row absorbs rounding dust so the whole amount is
    ///      conserved. `tranches > 0` registers a vesting lock on the recipient. The token's
    ///      2% first-day cap reverts the whole call if any recipient would exceed it. Callers
    ///      MUST have run {_validateLocks} on `locks` first.
    function _distribute(address token, uint256 purchased, LockOrder[] memory locks) private {
        uint256 n = locks.length;
        uint256 allocated;
        for (uint256 i; i < n; ++i) {
            LockOrder memory lo = locks[i];
            uint256 amount = (i == n - 1) ? purchased - allocated : DiggerMath.md512(purchased, lo.shareWad, WAD);
            allocated += amount;
            if (amount == 0) continue;

            DiggersToken(token).transfer(lo.to, amount);
            if (lo.tranches > 0) {
                DiggersToken(token).registerLock(lo.to, uint128(amount), lo.duration, lo.tranches);
            }
        }
    }

    // ------------------------------------------------------------- registry

    /// @notice Extend the reservation on both of a graduated token's registry objects.
    ///         Anyone may pay; 1 ETH = 365 days linear; each object's clock advances from
    ///         `max(current, now) + bought`, capped at `now + 100y`. One payment covers
    ///         both objects. Proceeds credit the team via the pull ledger. No refunds.
    /// @param token The graduated token to reserve for.
    function extendReservation(address token) external payable {
        _requireToken(token);
        DiggerRegistryLib.extend(_registry, _graduatedAt, _tokenKeys, ethOwed, feeRecipient, token, msg.value);
    }

    /// @notice Whether a name could be created right now (its reservation clock has lapsed).
    function isNameFree(string calldata name) external view returns (bool) {
        return DiggerRegistryLib.isNameFree(_registry, name);
    }

    /// @notice Whether a symbol could be created right now (its reservation clock has lapsed).
    function isSymbolFree(string calldata symbol) external view returns (bool) {
        return DiggerRegistryLib.isSymbolFree(_registry, symbol);
    }

    /// @notice Registry state for a name object and a symbol object (same shared set).
    function keyStateOf(string calldata name, string calldata symbol)
        external
        view
        returns (KeyState memory nameState, KeyState memory symbolState)
    {
        return DiggerRegistryLib.keyStateOf(_registry, name, symbol);
    }

    /// @notice The two registry objects `token` holds (folded name + folded symbol).
    function tokenKeys(address token) external view returns (TokenKeys memory) {
        _requireToken(token);
        return _tokenKeys[token];
    }

    /// @notice When `token` graduated (unix seconds); 0 if it never has.
    function graduatedAt(address token) external view returns (uint64) {
        _requireToken(token);
        return _graduatedAt[token];
    }

    // ----------------------------------------------------------- graduation

    /// @notice Graduate a token once it meets all three criteria (≥500 holders, ≥540 ETH
    ///         cumulative volume, ≥270 ETH mean-daily-tick market cap). Permissionless.
    ///         Sets `graduatedAt`; if within the first 24h it freely reserves any object
    ///         it was the first to mint. Usually automatic on trades; this is the explicit
    ///         path for tokens that cross the line afterwards.
    function graduate(address token) external {
        _requireToken(token);
        DiggerGraduationLib.graduate(_registry, _graduatedAt, _tokenKeys, token);
    }

    /// @notice Read-only graduation progress for UI progress bars.
    /// @param token The token to inspect.
    /// @return holders Current unique pool-verified holders.
    /// @return volumeEth Cumulative ETH-equivalent volume (wei).
    /// @return avgMcapEth Mean-tick market cap (wei).
    /// @return freeWindowEndsAt End of the token's free 24h window (unix seconds).
    /// @return reservedUntil Reservation clock covering both objects (min of the two).
    /// @return passes Three criteria flags [holders, volume, mcap].
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
        )
    {
        _requireToken(token);
        return DiggerGraduationLib.progress(_registry, _tokenKeys, token);
    }

    // --------------------------------------------------------------- fees

    /// @notice Collect accrued LP fees from the V4 pool and split per protocol rules.
    ///         ETH → team + platform + creator table (pull credits). Token-side → burn
    ///         share burned + remainder to daily pot.
    function harvest(address token) external {
        _harvest(token);
    }

    /// @notice Withdraw accumulated ETH fee credits from the pull-payment ledger.
    function claim() external nonReentrant {
        uint256 owed = ethOwed[msg.sender];
        if (owed == 0) revert NothingToClaim();
        ethOwed[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: owed}("");
        if (!ok) revert EthTransferFailed();
        emit Claimed(msg.sender, owed);
    }

    /// @notice Creator fee-split table size for a launched token.
    function feeSplitCount(address token) external view returns (uint8) {
        _requireToken(token);
        return _feeSplitCount[token];
    }

    /// @notice One row of the creator fee-split table (`{to, share}`).
    function feeSplitAt(address token, uint256 index) external view returns (FeeSplit memory) {
        _requireToken(token);
        if (index >= _feeSplitCount[token]) revert UnknownToken();
        return _feeSplits[token][index];
    }

    // ---------------------------------------------------- per-token ownership

    /// @notice Replace a token's creator ETH fee-split table (fee owner only). 1–10 rows,
    ///         every recipient non-zero, shares sum to exactly 1e18. Fully replaces the
    ///         previous table; takes effect from the next harvest.
    function setFeeSplits(address token, FeeSplit[] calldata rows) external onlyFeeOwner(token) {
        // Validation + storage write + `FeeSplitUpdated` live in the create library
        // (delegatecall) to keep this bytecode off the singleton's EIP-170 budget.
        DiggerCreateLib.updateFeeSplits(_feeSplitCount, _feeSplits, token, rows);
    }

    /// @notice Update a token's token-side burn share (burn owner only). `burnShareWad` is
    ///         1e18-scaled and must be ≤ 1e18; the daily traders-airdrop pot receives the
    ///         remainder. Takes effect from the next harvest.
    function setBurnShare(address token, uint256 burnShareWad) external onlyBurnOwner(token) {
        if (burnShareWad > WAD) revert BurnShareInvalid();
        _tokenRecords[token].burnShareWad = uint128(burnShareWad);
        emit BurnShareUpdated(token, burnShareWad);
    }

    /// @notice Transfer a token's fee-split ownership to a new non-zero address (fee owner only).
    function transferFeeOwnership(address token, address newOwner) external onlyFeeOwner(token) {
        if (newOwner == address(0)) revert OwnerRequired();
        feeOwner[token] = newOwner;
        emit FeeOwnershipTransferred(token, msg.sender, newOwner);
    }

    /// @notice Renounce a token's fee-split ownership forever — the ETH fee table freezes
    ///         at its current config and fees keep flowing.
    function renounceFeeOwnership(address token) external onlyFeeOwner(token) {
        feeOwner[token] = address(0);
        emit FeeOwnershipTransferred(token, msg.sender, address(0));
    }

    /// @notice Transfer a token's burn-share ownership to a new non-zero address (burn owner only).
    function transferBurnOwnership(address token, address newOwner) external onlyBurnOwner(token) {
        if (newOwner == address(0)) revert OwnerRequired();
        burnOwner[token] = newOwner;
        emit BurnOwnershipTransferred(token, msg.sender, newOwner);
    }

    /// @notice Renounce a token's burn-share ownership forever — the burn share freezes at
    ///         its current value and fees keep flowing.
    function renounceBurnOwnership(address token) external onlyBurnOwner(token) {
        burnOwner[token] = address(0);
        emit BurnOwnershipTransferred(token, msg.sender, address(0));
    }

    // -------------------------------------------------------------- router

    /// @notice Buy tokens with exact ETH. Output goes directly from the PoolManager to
    ///         `to` (defaults to `msg.sender` when zero). Mandatory slippage floor.
    /// @param token Launched DiggersToken.
    /// @param minOut Minimum tokens out.
    /// @param to Recipient; address(0) means `msg.sender`.
    function buy(address token, uint256 minOut, address to) external payable {
        if (msg.value == 0) revert ZeroEth();
        _trade(token, true, msg.value, minOut, to == address(0) ? msg.sender : to, false);
    }

    /// @notice Sell tokens for ETH. No approve needed — pulls directly from the caller to
    ///         the PoolManager via the silent router exemption.
    /// @param token Launched DiggersToken.
    /// @param amountIn Tokens to sell (18 dec).
    /// @param minOut Minimum ETH out (wei).
    /// @param to ETH recipient; address(0) means `msg.sender`.
    function sell(address token, uint256 amountIn, uint256 minOut, address to) external {
        if (amountIn == 0) revert ZeroSwapAmount();
        _trade(token, false, amountIn, minOut, to == address(0) ? msg.sender : to, true);
    }

    /// @notice Split the caller's own tokens across ≤10 recipients, optionally vesting each,
    ///         in one transaction. Pulls `amount` from `msg.sender` approve-free (the launchpad
    ///         only ever pulls `from == msg.sender` of the outer call). Pure p2p — no pool leg,
    ///         so no points/volume/holder credit. The 2% first-day cap applies per recipient.
    /// @param token Launched DiggersToken.
    /// @param amount Tokens to pull from the caller (18 dec).
    /// @param locks Distribution + vesting orders (1..10, shares sum 1e18).
    function transferAndLock(address token, uint256 amount, LockOrder[] calldata locks) external nonReentrant {
        _requireToken(token);
        if (amount == 0) revert ZeroSwapAmount();
        LockOrder[] memory locksMem = locks;
        _validateLocks(locksMem);

        DiggersToken(token).transferFrom(msg.sender, address(this), amount);
        _distribute(token, amount, locksMem);
    }

    /// @notice Buy with exact ETH, then split the purchased tokens across ≤10 recipients,
    ///         optionally vesting each — the post-launch equivalent of a create-time locked
    ///         initial buy. The swap output is aggregated on the launchpad (cap- and
    ///         points-exempt) then distributed per `locks`.
    /// @param token Launched DiggersToken.
    /// @param minOut Minimum tokens the buy must return (slippage floor).
    /// @param locks Distribution + vesting orders (1..10, shares sum 1e18).
    function buyAndLock(address token, uint256 minOut, LockOrder[] calldata locks) external payable {
        if (msg.value == 0) revert ZeroEth();
        _requireToken(token);
        LockOrder[] memory locksMem = locks;
        _validateLocks(locksMem);

        _maybeHarvest(token);
        DiggerV4.SwapOutcome memory out = _swapV4(_poolKey(token), true, msg.value, address(this), minOut);
        _emitSwapped(token, msg.sender, true, out.amountIn, out.amountOut);
        _distribute(token, out.amountOut, locksMem);

        DiggerGraduationLib.autoReserve(_registry, _graduatedAt, _tokenKeys, token);
    }

    /// @notice Quote tokens out for an exact ETH input (fee-inclusive, view-only).
    function quoteBuy(address token, uint256 ethIn) external view returns (uint256 amountOut) {
        return _quote(token, true, ethIn);
    }

    /// @notice Quote ETH out for an exact token input (fee-inclusive, view-only).
    function quoteSell(address token, uint256 tokenIn) external view returns (uint256 amountOut) {
        return _quote(token, false, tokenIn);
    }

    /// @notice Launch sqrt price for every pool (Q64.96), derived from `START_TICK`.
    function START_SQRT_PRICE_X96() external view returns (uint160) {
        return DiggerV4.getSqrtRatioAtTick(START_TICK);
    }

    // ------------------------------------------------------------------ views

    /// @notice Pool record for a launched token (creator, poolId, tick bounds, poolFee, burnShareWad).
    function tokenRecord(address token) external view returns (TokenRecord memory) {
        if (!isDiggersToken[token]) revert UnknownToken();
        return _tokenRecords[token];
    }

    /// @notice Monotonic nonce used in CREATE2 salts (creator, symbol, nonce).
    function createNonce() external view returns (uint256) {
        return _createNonce;
    }

    /// @notice The V4 PoolManager this launchpad routes every pool through.
    function poolManager() external view returns (address) {
        return POOL_MANAGER;
    }

    /// @notice Live pool snapshot for indexer reconciliation. NOT a per-pageview read — the
    ///         UI derives price/depth from the `Swapped`/`Created` log stream. Prefer events;
    ///         use this only to periodically reconcile cached state against chain.
    /// @return sqrtPriceX96 Current pool sqrt price (Q64.96).
    /// @return tick Current pool tick.
    /// @return liquidity Active liquidity of the single seeded position.
    /// @return ethInPool Virtual ETH reserve of the position at spot (wei).
    /// @return tokenInPool Virtual token reserve of the position at spot.
    function poolState(address token)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint128 liquidity, uint256 ethInPool, uint256 tokenInPool)
    {
        _requireToken(token);
        TokenRecord memory rec = _tokenRecords[token];
        DiggerSwapViews.State memory s =
            DiggerSwapViews.afterSwap(POOL_MANAGER, rec.poolId, rec.tickLower, rec.tickUpper);
        return (s.sqrtPriceX96, s.tick, s.liquidity, s.ethInPool, s.tokenInPool);
    }

    /// @notice Exact uncollected LP fees awaiting the next harvest, for indexer reconciliation.
    /// @return ethFees Uncollected ETH-side fees (wei).
    /// @return tokenFees Uncollected token-side fees.
    function pendingFees(address token) external view returns (uint256 ethFees, uint256 tokenFees) {
        _requireToken(token);
        TokenRecord memory rec = _tokenRecords[token];
        return DiggerHarvestViews.pendingFees(
            POOL_MANAGER, rec.poolId, address(this), rec.tickLower, rec.tickUpper, DiggerV4.positionSalt(address(this))
        );
    }

    // -------------------------------------------------------- token event hub

    /// @dev Only a token launched here may drive the hub — guards against forged events.
    modifier onlyLaunchedToken() {
        if (!isDiggersToken[msg.sender]) revert UnknownToken();
        _;
    }

    /// @notice Emit `PoolTrade` for the calling token's pool leg. Only callable by a
    ///         launched DiggersToken — guards against forged protocol events.
    function logPoolTrade(
        address trader,
        bool isBuy,
        uint256 tokenAmount,
        uint256 ethValue,
        int24 tick,
        uint32 holdersAfter,
        uint256 volumeEthCumAfter,
        uint256 epoch
    ) external onlyLaunchedToken {
        emit PoolTrade(msg.sender, trader, isBuy, tokenAmount, ethValue, tick, holdersAfter, volumeEthCumAfter, epoch);
    }

    /// @notice Emit `PointsCredited` for the calling token.
    function logPoints(
        uint256 epoch,
        address trader,
        bool isBuy,
        uint256 pointsEarned,
        uint256 newScore,
        uint256 lifetimeScore
    ) external onlyLaunchedToken {
        emit PointsCredited(msg.sender, epoch, trader, isBuy, pointsEarned, newScore, lifetimeScore);
    }

    /// @notice Emit `LeaderboardChanged` for the calling token.
    function logLeaderboard(uint256 epoch, address entrant, address evicted, uint256 entrantScore)
        external
        onlyLaunchedToken
    {
        emit LeaderboardChanged(msg.sender, epoch, entrant, evicted, entrantScore);
    }

    /// @notice Emit `HolderCountChanged` for the calling token.
    function logHolderCount(address holder, bool added, uint32 holderCountAfter) external onlyLaunchedToken {
        emit HolderCountChanged(msg.sender, holder, added, holderCountAfter);
    }

    /// @notice Emit `EpochSettled` for the calling token.
    function logEpochSettled(uint256 epoch, uint256 potPerWinner, uint256 rolledOver, uint64 nextDeadline)
        external
        onlyLaunchedToken
    {
        emit EpochSettled(msg.sender, epoch, potPerWinner, rolledOver, nextDeadline);
    }

    /// @notice Emit `AirdropPaid` for the calling token.
    function logAirdropPaid(uint256 epoch, address winner, uint256 amount) external onlyLaunchedToken {
        emit AirdropPaid(msg.sender, epoch, winner, amount);
    }

    /// @notice Emit `LockSet` for the calling token.
    function logLockSet(address holder, uint128 total, uint64 start, uint64 duration, uint32 tranches)
        external
        onlyLaunchedToken
    {
        emit LockSet(msg.sender, holder, total, start, duration, tranches);
    }

    // --------------------------------------------------------------- internal

    function _requireToken(address token) private view {
        if (!isDiggersToken[token]) revert UnknownToken();
    }

    function _poolKey(address token) private view returns (IPoolManagerLite.PoolKey memory key) {
        (key,) = DiggerV4.createPoolKey(token, _tokenRecords[token].poolFee, POOL_TICK_SPACING);
    }

    function _trade(
        address token,
        bool isBuy,
        uint256 amountIn,
        uint256 minOut,
        address recipient,
        bool sellMode
    ) private {
        _requireToken(token);
        _maybeHarvest(token);
        if (sellMode) _stashSellPayer(msg.sender);
        DiggerV4.SwapOutcome memory out = _swapV4(_poolKey(token), isBuy, amountIn, recipient, minOut);
        if (sellMode) _dropSellPayer();
        _emitSwapped(
            token,
            msg.sender,
            isBuy,
            isBuy ? out.amountIn : out.amountOut,
            isBuy ? out.amountOut : out.amountIn
        );

        // First-minter automation: within the token's first 24h, a passing token auto-
        // graduates + reserves its objects here so the community needs no manual call.
        // Silent (never reverts the trade); cheap early-return for copies / post-24h.
        DiggerGraduationLib.autoReserve(_registry, _graduatedAt, _tokenKeys, token);
    }

    function _maybeHarvest(address token) private {
        TokenRecord memory rec = _tokenRecords[token];
        if (
            !DiggerHarvestViews.shouldHarvest(
                POOL_MANAGER,
                rec.poolId,
                address(this),
                rec.tickLower,
                rec.tickUpper,
                DiggerV4.positionSalt(address(this)),
                HARVEST_THRESHOLD_ETH,
                HARVEST_THRESHOLD_TOKEN
            )
        ) return;
        _harvest(token);
    }

    /// @dev `nonReentrant` guards the ETH-push path (harvest now sends ETH). Distribution
    ///      runs AFTER `_collectFeesV4`'s unlock has returned, so the latch never spans a
    ///      PoolManager callback (`unlockCallback` is gated only on `msg.sender`, not this
    ///      latch), and pushes are gas-capped inside the harvest library.
    function _harvest(address token) private nonReentrant {
        _requireToken(token);
        TokenRecord memory rec = _tokenRecords[token];

        (uint256 ethFees, uint256 tokenFees) = _collectFeesV4(
            _poolKey(token), address(this), address(this), rec.tickLower, rec.tickUpper
        );

        // Carry any previously-undeliverable creator ETH into this round's creator side.
        uint256 carried = pendingEth[token];
        if (ethFees == 0 && tokenFees == 0 && carried == 0) return;
        if (carried > 0) pendingEth[token] = 0;

        DiggerHarvestLib.distribute(
            ethOwed,
            pendingEth,
            _feeSplits[token],
            _feeSplitCount[token],
            feeRecipient,
            feeOwner[token],
            token,
            msg.sender,
            ethFees,
            carried,
            tokenFees,
            rec.burnShareWad,
            teamShareWad,
            PLATFORM_TOKEN,
            airdropActive()
        );
    }

    function _quote(address token, bool zeroForOne, uint256 amountIn) private view returns (uint256) {
        _requireToken(token);
        return DiggerQuotes.quoteExactInput(POOL_MANAGER, _poolKey(token), zeroForOne, amountIn);
    }

    function _emitSwapped(
        address token,
        address trader,
        bool isBuy,
        uint256 ethAmount,
        uint256 tokenAmount
    ) private {
        TokenRecord memory rec = _tokenRecords[token];
        DiggerSwapViews.State memory s = DiggerSwapViews.afterSwap(
            POOL_MANAGER, rec.poolId, rec.tickLower, rec.tickUpper
        );

        emit Swapped(
            token,
            trader,
            isBuy,
            ethAmount,
            tokenAmount,
            s.sqrtPriceX96,
            s.tick,
            s.liquidity,
            s.ethInPool,
            s.tokenInPool
        );
    }

    function _stashSellPayer(address payer) private {
        bytes32 slot = keccak256(abi.encodePacked(address(this), SELL_PAYER_SLOT));
        assembly {
            tstore(slot, payer)
        }
    }

    function _loadSellPayer() private view returns (address payer) {
        bytes32 slot = keccak256(abi.encodePacked(address(this), SELL_PAYER_SLOT));
        assembly {
            payer := tload(slot)
        }
    }

    function _dropSellPayer() private {
        bytes32 slot = keccak256(abi.encodePacked(address(this), SELL_PAYER_SLOT));
        assembly {
            tstore(slot, 0)
        }
    }

    /// @dev Transfers tokens for V4 settlement. If a sell payer is stashed in transient
    ///      storage, pulls from that address via `transferFrom` (approve-free); otherwise
    ///      sends from the launchpad's own balance.
    function _transferToken(address token, address to, uint256 amount) internal override {
        address payer = _loadSellPayer();
        if (payer != address(0)) {
            DiggersToken(token).transferFrom(payer, to, amount);
        } else {
            DiggersToken(token).transfer(to, amount);
        }
    }
}
