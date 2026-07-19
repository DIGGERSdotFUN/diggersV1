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

    /// @inheritdoc IDiggers
    function airdropActive() public view returns (bool) {
        return airdropStart != 0 && block.timestamp < airdropEnd;
    }

    /// @inheritdoc IDiggers
    function startAirdrop() external onlyOwner {
        if (airdropStart != 0) revert AirdropAlreadyStarted();
        if (teamShareWad < PLATFORM_SLICE_WAD) revert TeamShareTooLow();
        uint64 start = uint64(block.timestamp);
        uint64 end = uint64(block.timestamp + AIRDROP_DURATION);
        airdropStart = start;
        airdropEnd = end;
        emit AirdropStarted(start, end);
    }

    /// @inheritdoc IDiggers
    function setTeamShareWad(uint256 newTeamShareWad) external onlyOwner {
        if (newTeamShareWad > WAD) revert TeamShareTooHigh();
        // While the airdrop is live the team side funds the 10% LP slice, so it may not
        // drop below it. Outside the window the owner may set any 0..100% split.
        if (airdropActive() && newTeamShareWad < PLATFORM_SLICE_WAD) revert TeamShareTooLow();
        teamShareWad = newTeamShareWad;
        emit TeamShareUpdated(newTeamShareWad);
    }

    /// @inheritdoc IDiggers
    function setFeeRecipient(address newFeeRecipient) external onlyOwner {
        if (newFeeRecipient == address(0)) revert TreasuryRequired();
        feeRecipient = newFeeRecipient;
        emit FeeRecipientUpdated(newFeeRecipient);
    }

    /// @inheritdoc IDiggers
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert OwnerRequired();
        address prev = owner;
        owner = newOwner;
        emit OwnershipTransferred(prev, newOwner);
    }

    /// @inheritdoc IDiggers
    function renounceOwnership() external onlyOwner {
        address prev = owner;
        owner = address(0);
        emit OwnershipTransferred(prev, address(0));
    }

    // ------------------------------------------------------------- receive

    /// @dev Accepts ETH for V4 settlement during unlock rounds (swaps land in step 10).
    receive() external payable {}

    // -------------------------------------------------------------- create

    /// @inheritdoc IDiggers
    /// @dev Convenience overload: no custom fee-split table, no distribution locks.
    ///      `msg.value` must cover CREATION_FEE; the remainder runs an atomic initial
    ///      buy routed to the creator (slippage 0).
    function create(TokenParams calldata params) external payable returns (address token) {
        FeeSplit[] memory noSplits = new FeeSplit[](0);
        LockOrder[] memory noLocks = new LockOrder[](0);
        return _create(params, noSplits, noLocks, 0);
    }

    /// @inheritdoc IDiggers
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

    /// @inheritdoc IDiggers
    function extendReservation(address token) external payable {
        _requireToken(token);
        DiggerRegistryLib.extend(_registry, _graduatedAt, _tokenKeys, ethOwed, feeRecipient, token, msg.value);
    }

    /// @inheritdoc IDiggers
    function isNameFree(string calldata name) external view returns (bool) {
        return DiggerRegistryLib.isNameFree(_registry, name);
    }

    /// @inheritdoc IDiggers
    function isSymbolFree(string calldata symbol) external view returns (bool) {
        return DiggerRegistryLib.isSymbolFree(_registry, symbol);
    }

    /// @inheritdoc IDiggers
    function keyStateOf(string calldata name, string calldata symbol)
        external
        view
        returns (KeyState memory nameState, KeyState memory symbolState)
    {
        return DiggerRegistryLib.keyStateOf(_registry, name, symbol);
    }

    /// @inheritdoc IDiggers
    function tokenKeys(address token) external view returns (TokenKeys memory) {
        _requireToken(token);
        return _tokenKeys[token];
    }

    /// @inheritdoc IDiggers
    function graduatedAt(address token) external view returns (uint64) {
        _requireToken(token);
        return _graduatedAt[token];
    }

    // ----------------------------------------------------------- graduation

    /// @inheritdoc IDiggers
    function graduate(address token) external {
        _requireToken(token);
        DiggerGraduationLib.graduate(_registry, _graduatedAt, _tokenKeys, token);
    }

    /// @inheritdoc IDiggers
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

    /// @inheritdoc IDiggers
    function harvest(address token) external {
        _harvest(token);
    }

    /// @inheritdoc IDiggers
    function claim() external nonReentrant {
        uint256 owed = ethOwed[msg.sender];
        if (owed == 0) revert NothingToClaim();
        ethOwed[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: owed}("");
        if (!ok) revert EthTransferFailed();
        emit Claimed(msg.sender, owed);
    }

    /// @inheritdoc IDiggers
    function feeSplitCount(address token) external view returns (uint8) {
        _requireToken(token);
        return _feeSplitCount[token];
    }

    /// @inheritdoc IDiggers
    function feeSplitAt(address token, uint256 index) external view returns (FeeSplit memory) {
        _requireToken(token);
        if (index >= _feeSplitCount[token]) revert UnknownToken();
        return _feeSplits[token][index];
    }

    // ---------------------------------------------------- per-token ownership

    /// @inheritdoc IDiggers
    function setFeeSplits(address token, FeeSplit[] calldata rows) external onlyFeeOwner(token) {
        // Validation + storage write + `FeeSplitUpdated` live in the create library
        // (delegatecall) to keep this bytecode off the singleton's EIP-170 budget.
        DiggerCreateLib.updateFeeSplits(_feeSplitCount, _feeSplits, token, rows);
    }

    /// @inheritdoc IDiggers
    function setBurnShare(address token, uint256 burnShareWad) external onlyBurnOwner(token) {
        if (burnShareWad > WAD) revert BurnShareInvalid();
        _tokenRecords[token].burnShareWad = uint128(burnShareWad);
        emit BurnShareUpdated(token, burnShareWad);
    }

    /// @inheritdoc IDiggers
    function transferFeeOwnership(address token, address newOwner) external onlyFeeOwner(token) {
        if (newOwner == address(0)) revert OwnerRequired();
        feeOwner[token] = newOwner;
        emit FeeOwnershipTransferred(token, msg.sender, newOwner);
    }

    /// @inheritdoc IDiggers
    function renounceFeeOwnership(address token) external onlyFeeOwner(token) {
        feeOwner[token] = address(0);
        emit FeeOwnershipTransferred(token, msg.sender, address(0));
    }

    /// @inheritdoc IDiggers
    function transferBurnOwnership(address token, address newOwner) external onlyBurnOwner(token) {
        if (newOwner == address(0)) revert OwnerRequired();
        burnOwner[token] = newOwner;
        emit BurnOwnershipTransferred(token, msg.sender, newOwner);
    }

    /// @inheritdoc IDiggers
    function renounceBurnOwnership(address token) external onlyBurnOwner(token) {
        burnOwner[token] = address(0);
        emit BurnOwnershipTransferred(token, msg.sender, address(0));
    }

    // -------------------------------------------------------------- router

    /// @inheritdoc IDiggers
    function buy(address token, uint256 minOut, address to) external payable {
        if (msg.value == 0) revert ZeroEth();
        _trade(token, true, msg.value, minOut, to == address(0) ? msg.sender : to, false);
    }

    /// @inheritdoc IDiggers
    function sell(address token, uint256 amountIn, uint256 minOut, address to) external {
        if (amountIn == 0) revert ZeroSwapAmount();
        _trade(token, false, amountIn, minOut, to == address(0) ? msg.sender : to, true);
    }

    /// @inheritdoc IDiggers
    /// @dev No swap, no ETH — pure token distribution — so it carries the `nonReentrant`
    ///      latch outright (unlike buy/sell, whose only ETH-sending step self-guards inside
    ///      `_harvest`). The approve-free pull moves ONLY the caller's own tokens: the token
    ///      skips the allowance solely because the launchpad is the `transferFrom` caller and
    ///      the launchpad only ever passes `from == msg.sender` of this outer call.
    function transferAndLock(address token, uint256 amount, LockOrder[] calldata locks) external nonReentrant {
        _requireToken(token);
        if (amount == 0) revert ZeroSwapAmount();
        LockOrder[] memory locksMem = locks;
        _validateLocks(locksMem);

        DiggersToken(token).transferFrom(msg.sender, address(this), amount);
        _distribute(token, amount, locksMem);
    }

    /// @inheritdoc IDiggers
    /// @dev Mirrors `buy` (opportunistic `_maybeHarvest`, rich `Swapped`, auto-reserve) but
    ///      routes the swap output to the launchpad for aggregation. The pool leg therefore
    ///      lands on the points/cap-exempt launchpad — no points, holder, or volume credit,
    ///      no `PoolTrade` — exactly like a create-time locked buy (sybil-neutral). NOT
    ///      `nonReentrant`: `_maybeHarvest` self-guards `_harvest`, so latching here would
    ///      double-acquire and revert.
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

    /// @inheritdoc IDiggers
    function quoteBuy(address token, uint256 ethIn) external view returns (uint256 amountOut) {
        return _quote(token, true, ethIn);
    }

    /// @inheritdoc IDiggers
    function quoteSell(address token, uint256 tokenIn) external view returns (uint256 amountOut) {
        return _quote(token, false, tokenIn);
    }

    /// @inheritdoc IDiggers
    function START_SQRT_PRICE_X96() external view returns (uint160) {
        return DiggerV4.getSqrtRatioAtTick(START_TICK);
    }

    // ------------------------------------------------------------------ views

    /// @inheritdoc IDiggers
    function tokenRecord(address token) external view returns (TokenRecord memory) {
        if (!isDiggersToken[token]) revert UnknownToken();
        return _tokenRecords[token];
    }

    /// @inheritdoc IDiggers
    function createNonce() external view returns (uint256) {
        return _createNonce;
    }

    /// @inheritdoc IDiggers
    function poolManager() external view returns (address) {
        return POOL_MANAGER;
    }

    /// @inheritdoc IDiggers
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

    /// @inheritdoc IDiggers
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

    /// @inheritdoc IDiggers
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

    /// @inheritdoc IDiggers
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

    /// @inheritdoc IDiggers
    function logLeaderboard(uint256 epoch, address entrant, address evicted, uint256 entrantScore)
        external
        onlyLaunchedToken
    {
        emit LeaderboardChanged(msg.sender, epoch, entrant, evicted, entrantScore);
    }

    /// @inheritdoc IDiggers
    function logHolderCount(address holder, bool added, uint32 holderCountAfter) external onlyLaunchedToken {
        emit HolderCountChanged(msg.sender, holder, added, holderCountAfter);
    }

    /// @inheritdoc IDiggers
    function logEpochSettled(uint256 epoch, uint256 potPerWinner, uint256 rolledOver, uint64 nextDeadline)
        external
        onlyLaunchedToken
    {
        emit EpochSettled(msg.sender, epoch, potPerWinner, rolledOver, nextDeadline);
    }

    /// @inheritdoc IDiggers
    function logAirdropPaid(uint256 epoch, address winner, uint256 amount) external onlyLaunchedToken {
        emit AirdropPaid(msg.sender, epoch, winner, amount);
    }

    /// @inheritdoc IDiggers
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

    /// @inheritdoc DiggerV4Base
    function _transferToken(address token, address to, uint256 amount) internal override {
        address payer = _loadSellPayer();
        if (payer != address(0)) {
            DiggersToken(token).transferFrom(payer, to, amount);
        } else {
            DiggersToken(token).transfer(to, amount);
        }
    }
}
