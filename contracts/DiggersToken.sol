// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

/**
 * @title DiggersToken
 * @notice The ERC20 behind every Diggers launch. ONE implementation is deployed by the
 *         launchpad's constructor; every launch is a 45-byte EIP-1167 minimal proxy of
 *         it, initialized in the creation tx (fixed 1e9·1e18 supply minted to the
 *         launchpad, which seeds it all into the V4 pool). 18 decimals, burnable,
 *         non-mintable, NOT upgradeable — the implementation has no admin and clones
 *         cannot be re-pointed. Hosts the first-day anti-whale cap and the silent
 *         router allowance exemption; later mechanisms (vesting locks, trader points,
 *         daily airdrop, graduation telemetry) all live in the same _update pipeline.
 * @author BasedDopamine
 */
import {DiggerMath} from "./libs/DiggerMath.sol";
import {DiggerV4} from "./libs/DiggerV4.sol";
import {IDiggers} from "./interfaces/IDiggers.sol";
import {IDiggersCoin} from "./interfaces/IDiggersCoin.sol";

contract DiggersToken {
    // ------------------------------------------------------------------- types

    /// @dev Tranche vesting lock. Tokens live in the holder's wallet but cannot
    ///      move while locked; `tranches` equal slices unlock evenly across
    ///      `duration` (tranches = 1 is a cliff at `duration`).
    struct Lock {
        // Total locked amount (raw token units, 18 dec)
        uint128 total;
        // Lock start timestamp (seconds)
        uint64 start;
        // Full vesting duration (seconds)
        uint64 duration;
        // Number of equal unlock slices
        uint32 tranches;
    }

    /// @dev One day's closing tick. `recorded` distinguishes a real tick-0 close
    ///      from an untraded gap day.
    struct DayTick {
        int24 tick;
        bool recorded;
    }

    // -------------------------------------------------- constants / immutables

    /// @notice Fixed total supply: 1 billion tokens, 18 decimals. Never increases.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;

    /// @dev First-day anti-whale recipient ceiling: 2% of supply.
    uint256 private constant WALLET_CAP = TOTAL_SUPPLY / 50;

    /// @dev Duration of the anti-whale window after launch (seconds).
    uint256 private constant CAP_WINDOW = 1 days;

    /// @dev Hard bound on lock recipients per token (keeps getLocks enumerable).
    uint256 private constant MAX_LOCKERS = 10;

    /// @dev Points per full-supply buy, 1e18-scaled (2e18 = double weight).
    uint256 private constant BUY_POINTS_WAD = 2e18;

    /// @dev Points per full-supply sell, 1e18-scaled (5e17 = half weight; a buy
    ///      earns 4x the same-size sell).
    uint256 private constant SELL_POINTS_WAD = 5e17;

    /// @dev Leaderboard width.
    uint256 private constant BOARD_SIZE = 10;

    /// @dev Length of one points epoch (seconds).
    uint256 private constant EPOCH_LENGTH = 1 days;

    /// @dev EIP-1153 transient slot for the distribution-mode flag. While set,
    ///      _update degrades to plain ERC20 moves; auto-clears at tx end.
    bytes32 private constant DISTRIBUTION_SLOT = keccak256("diggers.token.distribution");

    /// @notice Tick spacing of every Diggers pool. Coupled with POOL_FEE into POOL_ID.
    int24 public constant POOL_TICK_SPACING = 200;

    /// @dev Window of the mean-tick walk (day indices examined, gap days skipped).
    uint256 private constant MEAN_TICK_WINDOW = 7;

    /// @notice The Diggers launchpad: factory, swap router, sole LP, fee harvester.
    ///         Set to the implementation's deployer (the launchpad constructs it) and
    ///         shared by every clone — immutables live in code, which clones delegate to.
    address public immutable LAUNCHPAD;

    /// @notice The Uniswap V4 PoolManager this token trades on. Shared by every clone.
    address public immutable POOL_MANAGER;

    /// @notice The platform coin. Each pool BUY during the airdrop window mints platform
    ///         coins to the buyer via `creditBuy`, priced off this trade's 10% fee slice.
    ///         Shared by every clone.
    address public immutable PLATFORM_TOKEN;

    /// @dev The platform fee-estimate denominator: V4 fees are in millionths of input.
    uint256 private constant FEE_PPM_DENOMINATOR = 1e6;

    /// @dev Platform slice of a trade's LP fee: one tenth (10%).
    uint256 private constant PLATFORM_FEE_DIVISOR = 10;

    // ---------------------------------------------------------------- storage

    /// @dev Launch timestamp (seconds); 0 until `initialize` — which makes it double as
    ///      the initialized flag. Packed with `_epochEnd` and `_poolFee` so the hot-path
    ///      cap check and epoch check share a single SLOAD.
    uint64 private _deployedAt;

    /// @dev Deadline of the current points epoch (seconds). Same slot as `_deployedAt`.
    uint64 private _epochEnd;

    /// @dev LP fee of this token's pool, V4 millionths (creator-chosen 10000..50000).
    ///      Same slot as `_deployedAt`.
    uint24 private _poolFee;

    /// @dev V4 pool id of this token's ETH pool. Deterministic (ETH/this, `_poolFee`,
    ///      spacing 200, hookless); derived once in `initialize` from the clone address.
    bytes32 private _poolId;

    /// @dev Account balances (raw token units, 18 dec).
    mapping(address => uint256) private _balances;

    /// @dev Standard ERC20 allowances (raw token units). NEVER touched when the
    ///      launchpad is the transferFrom caller.
    mapping(address => mapping(address => uint256)) private _allowances;

    /// @dev Live supply (raw token units); starts at TOTAL_SUPPLY, only burns move it.
    uint256 private _totalSupply;

    /// @dev Token name (immutable in practice; strings cannot be immutable).
    string private _name;

    /// @dev Token symbol.
    string private _symbol;

    /// @notice ipfs:// URI of the launch metadata JSON. The chain stores only this.
    string public metadataURI;

    /// @dev Vesting locks, at most one per address ever (raw token units inside).
    mapping(address => Lock) private _locks;

    /// @dev Every address that ever received a lock; bounded at MAX_LOCKERS.
    address[] private _lockers;

    /// @dev Trader points, 1e18-scaled, keyed by epoch then trader. Epoch-keying IS
    ///      the daily reset: bumping `epoch` wipes every score in O(1); per-user
    ///      iteration does not exist anywhere in this contract.
    mapping(uint256 => mapping(address => uint256)) private _points;

    /// @dev All-time trader points, 1e18-scaled, NEVER reset by an epoch roll. Purely
    ///      cosmetic ("digger score") — the daily airdrop reads `_points[epoch]`, never
    ///      this. Monotonic: only ever grows by the same `pointsEarned` credited to the
    ///      epoch score, so it equals the sum of every epoch score a trader ever earned.
    mapping(address => uint256) private _lifetimePoints;

    /// @dev Top-10 board per epoch. Min-slot replacement, no sorting, ties keep the
    ///      incumbent. address(0) slots read as zero points.
    mapping(uint256 => address[BOARD_SIZE]) private _leaders;

    /// @notice Unique pool-verified holders right now. Only pool buys add; emptying
    ///         a wallet by any route removes. The graduation criterion reads this.
    uint32 public holderCount;

    /// @dev Whether an address is currently included in holderCount. The flag (not
    ///      a balance heuristic) is what keeps the counter exactly consistent.
    mapping(address => bool) private _counted;

    /// @notice Cumulative ETH-equivalent volume through the pool, in wei, priced at
    ///         the pool's own spot each leg — identical no matter which router.
    uint256 public volumeEthCum;

    /// @dev Daily closing tick per day-index (block.timestamp / 1 days). Overwrite
    ///      semantics: the stored value is the day's LAST trade tick.
    mapping(uint256 => DayTick) private _dailyTick;

    /// @notice Current points epoch id (starts at 0, bumps on each lazy roll).
    uint256 public epoch;

    // ----------------------------------------------------------------- events

    /// @notice Standard ERC20 transfer event (also for mint/burn legs).
    event Transfer(address indexed from, address indexed to, uint256 value);

    /// @notice Standard ERC20 approval event.
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /// @dev Every OTHER token event (trades, points, leaderboard, holder count, epoch
    ///      settlement, airdrops, locks) is NOT emitted here — the token forwards them to
    ///      the launchpad's event hub (`IDiggers.log*`), which re-emits with `token`
    ///      indexed. This keeps the whole protocol's log stream on ONE address; only the
    ///      plain ERC20 `Transfer`/`Approval` stay on the token itself.

    // ----------------------------------------------------------------- errors

    /// @notice Sender balance is below the requested amount.
    error BalanceTooLow(uint256 balance, uint256 needed);

    /// @notice Spender allowance is below the requested amount.
    error AllowanceTooLow(uint256 allowance, uint256 needed);

    /// @notice First-day anti-whale: recipient would exceed 2% of total supply.
    error CapExceeded();

    /// @notice Zero address where a real account is required.
    error ZeroAddress();

    /// @notice Caller must be the launchpad.
    error NotLaunchpad();

    /// @notice The address already has a lock (one per address, forever).
    error LockExists();

    /// @notice This token already carries the maximum number of locks.
    error TooManyLocks();

    /// @notice Lock total, duration, and tranches must all be non-zero.
    error LockParamsInvalid();

    /// @notice The transfer would dip into the sender's still-locked balance.
    error LockActive(uint256 lockedRemaining, uint256 balanceAfter);

    /// @notice `initialize` was already called on this clone (once, ever).
    error AlreadyInitialized();

    // ------------------------------------------------------------ constructor

    /**
     * @notice Deploys the SHARED implementation. Runs once, from the launchpad's own
     *         constructor — every launch afterwards is an EIP-1167 clone of this code.
     * @dev The caller IS the launchpad, baked in as an immutable every clone reads
     *      through delegatecall. The implementation itself is never initialized (the
     *      launchpad only initializes fresh clones), so it holds no supply and its
     *      hub callbacks would revert — it is permanently inert.
     * @param poolManager The V4 PoolManager address (shared by every launch).
     * @param platformToken The platform coin credited on buy legs during the airdrop.
     */
    constructor(address poolManager, address platformToken) {
        if (poolManager == address(0)) revert ZeroAddress();
        LAUNCHPAD = msg.sender;
        POOL_MANAGER = poolManager;
        PLATFORM_TOKEN = platformToken;
    }

    // ------------------------------------------------------------------ external

    /**
     * @notice Arms a fresh clone: identity, pool config, epoch clock, and the one and
     *         only supply mint (to the launchpad, which seeds it all into the pool).
     * @dev Launchpad-only and once-only — `_deployedAt == 0` IS the uninitialized flag,
     *      and the launchpad calls this in the same tx as the CREATE2 clone, so there
     *      is no window in which an unarmed clone exists. No mint path exists anywhere
     *      else in this contract.
     * @param name_ Token name (charset enforced by the launchpad's registry).
     * @param symbol_ Token symbol.
     * @param metadataURI_ ipfs:// metadata JSON pinned before the create tx.
     * @param poolFee_ LP fee in V4 millionths (10000..50000); the launchpad validates
     *        the range and reuses it in the pool key so POOL_ID matches.
     */
    function initialize(
        string calldata name_,
        string calldata symbol_,
        string calldata metadataURI_,
        uint24 poolFee_
    ) external {
        if (msg.sender != LAUNCHPAD) revert NotLaunchpad();
        if (_deployedAt != 0) revert AlreadyInitialized();

        _deployedAt = uint64(block.timestamp);
        _epochEnd = uint64(block.timestamp + EPOCH_LENGTH);
        _poolFee = poolFee_;
        (, _poolId) = DiggerV4.createPoolKey(address(this), poolFee_, POOL_TICK_SPACING);
        _name = name_;
        _symbol = symbol_;
        metadataURI = metadataURI_;

        _update(address(0), msg.sender, TOTAL_SUPPLY);
    }

    /**
     * @notice Standard ERC20 transfer.
     * @param to Recipient (subject to the first-day cap unless exempt).
     * @param amount Token amount (18 dec).
     * @return Always true; failures revert.
     */
    function transfer(address to, uint256 amount) external returns (bool) {
        if (to == address(0)) revert ZeroAddress();
        _update(msg.sender, to, amount);
        return true;
    }

    /**
     * @notice Standard ERC20 approve.
     * @dev Approving the launchpad is never necessary — see {transferFrom}.
     */
    function approve(address spender, uint256 amount) external returns (bool) {
        if (spender == address(0)) revert ZeroAddress();
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /**
     * @notice Standard transferFrom — EXCEPT when the launchpad is the caller.
     * @dev LOUD DISCLOSURE: when `msg.sender == LAUNCHPAD` the allowance branch is
     *      skipped entirely — no allowance is read, none is written, and wallets or
     *      explorers show nothing to revoke. This is what makes sells approve-free.
     *      The trust boundary: the launchpad never calls transferFrom with a `from`
     *      other than its own caller, and only inside `sell` and `transferAndLock`
     *      (enforced there and fuzz-tested as an invariant). All other callers follow the
     *      standard ERC20 allowance path, with the usual infinite-allowance
     *      no-decrement convention.
     */
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (to == address(0)) revert ZeroAddress();
        if (msg.sender != LAUNCHPAD) {
            uint256 allowed = _allowances[from][msg.sender];
            if (allowed != type(uint256).max) {
                if (allowed < amount) revert AllowanceTooLow(allowed, amount);
                unchecked {
                    _allowances[from][msg.sender] = allowed - amount;
                }
            }
        }
        _update(from, to, amount);
        return true;
    }

    /**
     * @notice Burns tokens from the caller. Total supply only ever goes down.
     * @dev Used by the launchpad's fee engine (90% of token-side fees burn) and open
     *      to anyone. Locked balances cannot be burned — the lock gate in _update
     *      applies to the burn leg like any other debit.
     */
    function burn(uint256 amount) external {
        _update(msg.sender, address(0), amount);
    }

    /**
     * @notice Registers a tranche vesting lock for `holder`. Launchpad-only, called during
     *         the create-time buy distribution and the post-launch `transferAndLock` /
     *         `buyAndLock` flows.
     * @dev One lock per address, ever — a second registration reverts, which keeps
     *      the unlock math trivial. The tokens themselves are transferred separately
     *      (they sit in the holder's wallet, visible but movement-gated). Bounded at
     *      10 lockers so getLocks stays cheaply enumerable.
     * @param holder Address whose balance becomes movement-gated.
     * @param total Locked amount (raw units); must be > 0.
     * @param duration Seconds until fully vested; must be > 0.
     * @param tranches Equal unlock slices (1 = cliff at duration); must be > 0.
     */
    function registerLock(address holder, uint128 total, uint64 duration, uint32 tranches) external {
        if (msg.sender != LAUNCHPAD) revert NotLaunchpad();
        if (holder == address(0)) revert ZeroAddress();
        if (total == 0 || duration == 0 || tranches == 0) revert LockParamsInvalid();
        if (_locks[holder].total != 0) revert LockExists();
        if (_lockers.length >= MAX_LOCKERS) revert TooManyLocks();

        uint64 start = uint64(block.timestamp);
        _locks[holder] = Lock({total: total, start: start, duration: duration, tranches: tranches});
        _lockers.push(holder);

        IDiggers(LAUNCHPAD).logLockSet(holder, total, start, duration, tranches);
    }

    // ----------------------------------------------------------------- internal

    /**
     * @dev The single balance-movement pipeline, in fixed order: (0) distribution
     *      short-circuit + lazy epoch settlement, (1) first-day anti-whale cap
     *      (checked BEFORE any balance write), (2) debit with the vesting gate,
     *      (3) credit, (4) points, (5) event. Step 8 adds telemetry around the
     *      pool legs.
     */
    function _update(address from, address to, uint256 amount) internal {
        // Airdrop distribution mode: plain ERC20 moves only. No points, no cap, no
        // lock gate, and crucially no epoch re-check — the roll condition is still
        // true while distributing, so this flag is what makes recursion impossible.
        if (_distributionMode()) {
            _plainMove(from, to, amount);
            return;
        }

        // One SLOAD covers both time gates: deployedAt, epochEnd, and poolFee share
        // a storage slot by design.
        uint64 deployedAt = _deployedAt;

        // Lazy daily settlement: the first transfer at or past the deadline pays
        // yesterday's board before its own logic runs, so the carrying transfer's
        // points land in the NEW epoch. Nobody needs to poke the contract.
        if (block.timestamp >= _epochEnd) {
            _settleEpoch();
        }

        // First-day anti-whale: recipients may not exceed 2% of supply. Timestamp
        // check first — after 24h this whole branch is one cold-free short-circuit.
        // Exemptions are structural, not courtesy: the PoolManager holds ~100% of
        // supply at launch (all pool tokens sit on the singleton), the launchpad
        // routes fee harvests, the token itself accumulates the airdrop pot, and
        // burns must never be blocked.
        if (
            block.timestamp < deployedAt + CAP_WINDOW && to != POOL_MANAGER && to != LAUNCHPAD
                && to != address(this) && to != address(0)
        ) {
            if (_balances[to] + amount > WALLET_CAP) revert CapExceeded();
        }

        // Pool-leg classification, shared by points and telemetry. Tokens leaving
        // the PoolManager are a buy, tokens entering it are a sell — but only when
        // the counterparty is a real trader: the launchpad (seeding, harvests), the
        // token itself (pot parking), and address(0) (burns/mint) don't trade.
        bool buyLeg = from == POOL_MANAGER && to != LAUNCHPAD && to != address(this) && to != address(0);
        bool sellLeg = to == POOL_MANAGER && from != LAUNCHPAD && from != address(this) && from != address(0);

        // Holder add — decided on the PRE-credit balance: a pool buy landing on an
        // empty, uncounted wallet counts it in. P2p receipts never add.
        if (buyLeg && _balances[to] == 0 && !_counted[to]) {
            _counted[to] = true;
            ++holderCount;
            IDiggers(LAUNCHPAD).logHolderCount(to, true, holderCount);
        }

        if (from == address(0)) {
            // Mint leg — reachable only from `initialize`.
            _totalSupply += amount;
        } else {
            uint256 fromBalance = _balances[from];
            if (fromBalance < amount) revert BalanceTooLow(fromBalance, amount);

            // Vesting gate: the post-debit balance must still cover whatever is
            // locked. Applies to every debit path — transfers, router sells, burns.
            uint256 locked = lockRemaining(from);
            if (locked > 0) {
                unchecked {
                    // fromBalance >= amount was just checked.
                    if (fromBalance - amount < locked) revert LockActive(locked, fromBalance - amount);
                }
            }

            unchecked {
                _balances[from] = fromBalance - amount;
            }

            // Holder remove — decided on the POST-debit balance: emptying a counted
            // wallet by ANY route (p2p, sell, burn) removes it. Splitting a stack to
            // fresh addresses removes the source WITHOUT adding the destinations.
            if (_balances[from] == 0 && _counted[from]) {
                _counted[from] = false;
                --holderCount;
                IDiggers(LAUNCHPAD).logHolderCount(from, false, holderCount);
            }
        }

        if (to == address(0)) {
            // Burn leg — supply strictly decreases, forever.
            unchecked {
                _totalSupply -= amount;
            }
        } else {
            unchecked {
                // Cannot overflow: the sum of all balances never exceeds supply.
                _balances[to] += amount;
            }
        }

        // Trader points: buys earn double weight, sells half (floor — points are
        // credits out of the system, rounded down).
        if (buyLeg) {
            _creditPoints(to, DiggerMath.md512(amount, BUY_POINTS_WAD, TOTAL_SUPPLY), true);
        } else if (sellLeg) {
            _creditPoints(from, DiggerMath.md512(amount, SELL_POINTS_WAD, TOTAL_SUPPLY), false);
        }

        // Telemetry + trade feed: price every pool leg at the pool's own spot, so
        // volume is router-agnostic. Runs last so the event snapshots final state.
        if (buyLeg || sellLeg) {
            DiggerV4.Slot0 memory slot0 = DiggerV4.getSlot0(POOL_MANAGER, _poolId);
            // Floor: ETH value credited to the volume stat rounds down.
            uint256 ethValue =
                DiggerMath.md512(amount, DiggerV4.sqrtPriceToInversePrice(slot0.sqrtPriceX96), 1e18);
            volumeEthCum += ethValue;
            _dailyTick[block.timestamp / 1 days] = DayTick({tick: slot0.tick, recorded: true});
            IDiggers(LAUNCHPAD).logPoolTrade(
                buyLeg ? to : from, buyLeg, amount, ethValue, slot0.tick, holderCount, volumeEthCum, epoch
            );

            // Platform buy-mining: on a pool BUY while the airdrop window is open, mint
            // platform coins to the buyer priced off this trade's 10% ETH fee slice.
            // Estimated from the same `ethValue` already computed for volume (no extra pool
            // reads). The window is owner-controlled, so it is read live from the launchpad
            // (one cheap staticcall) rather than baked into an immutable. `creditBuy` is
            // silent on dust and only reverts on inputs that can never occur here, so it
            // can never brick the carrying trade.
            if (buyLeg && IDiggers(LAUNCHPAD).airdropActive()) {
                uint256 feeEthEst = DiggerMath.md512(ethValue, _poolFee, FEE_PPM_DENOMINATOR);
                IDiggersCoin(PLATFORM_TOKEN).creditBuy(to, feeEthEst / PLATFORM_FEE_DIVISOR);
            }
        }

        emit Transfer(from, to, amount);
    }

    /**
     * @dev Closes the current epoch: pays pot/10 to every closing-board leader that
     *      still holds tokens, rolls the rest (empty slots, sold-out leaders,
     *      division dust) into the next day's pot, bumps the epoch (which IS the
     *      points reset), and re-anchors the deadline to trigger-time + 24h.
     *      MUST NOT revert the carrying transfer: no external calls, payouts are
     *      self-transfers of at most pot/10 each to nonzero addresses, and the
     *      contract's balance covers them by construction.
     */
    function _settleEpoch() private {
        uint256 closing = epoch;
        uint256 pot = _balances[address(this)];
        uint256 share = pot / BOARD_SIZE;
        uint256 paidOut;

        if (share > 0) {
            _setDistributionMode(true);
            address[BOARD_SIZE] storage board = _leaders[closing];
            for (uint256 i; i < BOARD_SIZE; ++i) {
                address winner = board[i];
                // Still-holds check: paper-handing before settlement forfeits the
                // share (it rolls over); empty slots skip naturally.
                if (winner == address(0) || _balances[winner] == 0) continue;
                _update(address(this), winner, share);
                paidOut += share;
                IDiggers(LAUNCHPAD).logAirdropPaid(closing, winner, share);
            }
            _setDistributionMode(false);
        }

        epoch = closing + 1;
        uint64 nextDeadline = uint64(block.timestamp + EPOCH_LENGTH);
        _epochEnd = nextDeadline;
        IDiggers(LAUNCHPAD).logEpochSettled(closing, share, pot - paidOut, nextDeadline);
    }

    /// @dev Plain ERC20 move used under distribution mode: debit, credit, event —
    ///      nothing else. Distribution never mints, burns, or overdraws, so the
    ///      balance check is a formality kept for defense in depth.
    function _plainMove(address from, address to, uint256 amount) private {
        uint256 fromBalance = _balances[from];
        if (fromBalance < amount) revert BalanceTooLow(fromBalance, amount);
        unchecked {
            _balances[from] = fromBalance - amount;
            _balances[to] += amount;
        }
        emit Transfer(from, to, amount);
    }

    /// @dev Reads the transient distribution flag.
    function _distributionMode() private view returns (bool active) {
        bytes32 slot = DISTRIBUTION_SLOT;
        assembly {
            active := tload(slot)
        }
    }

    /// @dev Writes the transient distribution flag (auto-clears at tx end anyway;
    ///      cleared eagerly for hygiene).
    function _setDistributionMode(bool active) private {
        bytes32 slot = DISTRIBUTION_SLOT;
        assembly {
            tstore(slot, active)
        }
    }

    /**
     * @dev Adds points to `trader` in the current epoch and refreshes the top-10
     *      board: one 10-slot scan that both detects "already on board" (stop — the
     *      slot's score just grew in place) and tracks the minimum-points slot;
     *      empty slots read as zero. The newcomer replaces the minimum only on a
     *      STRICT improvement, so ties keep the incumbent.
     */
    function _creditPoints(address trader, uint256 pointsEarned, bool isBuy) private {
        if (pointsEarned == 0) return;

        uint256 currentEpoch = epoch;
        uint256 newScore = _points[currentEpoch][trader] + pointsEarned;
        _points[currentEpoch][trader] = newScore;
        // Cosmetic all-time tally: grows with the epoch score, never resets.
        uint256 lifetimeScore = _lifetimePoints[trader] + pointsEarned;
        _lifetimePoints[trader] = lifetimeScore;
        IDiggers(LAUNCHPAD).logPoints(currentEpoch, trader, isBuy, pointsEarned, newScore, lifetimeScore);

        address[BOARD_SIZE] storage board = _leaders[currentEpoch];
        uint256 minScore = type(uint256).max;
        uint256 minSlot = 0;
        for (uint256 i; i < BOARD_SIZE; ++i) {
            address occupant = board[i];
            if (occupant == trader) return;
            // points[epoch][address(0)] is always zero, so empty slots need no case.
            uint256 occupantScore = _points[currentEpoch][occupant];
            if (occupantScore < minScore) {
                minScore = occupantScore;
                minSlot = i;
            }
        }
        if (newScore > minScore) {
            address evicted = board[minSlot];
            board[minSlot] = trader;
            IDiggers(LAUNCHPAD).logLeaderboard(currentEpoch, trader, evicted, newScore);
        }
    }

    // -------------------------------------------------------------------- views

    /// @notice Launch timestamp (seconds); anchors the 24h anti-whale window. 0 only
    ///         on the never-initialized implementation.
    function DEPLOYED_AT() external view returns (uint64) {
        return _deployedAt;
    }

    /// @notice LP fee of this token's pool, in V4 millionths (creator-chosen at launch,
    ///         10000..50000 == 1%..5%). The launchpad reuses it in the pool key so
    ///         POOL_ID matches.
    function POOL_FEE() external view returns (uint24) {
        return _poolFee;
    }

    /// @notice V4 pool id of this token's ETH pool. Fully deterministic (ETH/this,
    ///         POOL_FEE, spacing 200, hookless), fixed at initialization.
    function POOL_ID() external view returns (bytes32) {
        return _poolId;
    }

    /// @notice Deadline of the current epoch (seconds). The first transfer at or past
    ///         it settles the day — anchored to that trigger, not a fixed daily grid.
    function epochEnd() external view returns (uint64) {
        return _epochEnd;
    }

    /// @notice Token name.
    function name() external view returns (string memory) {
        return _name;
    }

    /// @notice Token symbol.
    function symbol() external view returns (string memory) {
        return _symbol;
    }

    /// @notice Always 18.
    function decimals() external pure returns (uint8) {
        return 18;
    }

    /// @notice Live supply: TOTAL_SUPPLY minus everything burned.
    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    /// @notice Balance of `account`.
    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    /// @notice Remaining allowance from `owner` to `spender`. Always irrelevant for
    ///         the launchpad, which never consults it.
    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }

    /// @notice Points of `trader` in the CURRENT epoch (1e18-scaled).
    function traderPoints(address trader) external view returns (uint256) {
        return _points[epoch][trader];
    }

    /// @notice Points of `trader` in an arbitrary epoch (past epochs stay readable).
    function pointsOf(uint256 epochId, address trader) external view returns (uint256) {
        return _points[epochId][trader];
    }

    /// @notice All-time points `trader` has earned across every epoch, 1e18-scaled.
    /// @dev Cosmetic leaderboard only — the daily airdrop ignores this and pays purely
    ///      off the current epoch's board. Never reset, so it only ever grows.
    function lifetimePoints(address trader) external view returns (uint256) {
        return _lifetimePoints[trader];
    }

    /**
     * @notice The current epoch's top-10 board with scores.
     * @dev Unsorted (slot order is arbitrary); empty slots are address(0)/0. The UI
     *      sorts client-side.
     */
    function currentLeaders() external view returns (address[BOARD_SIZE] memory board, uint256[BOARD_SIZE] memory scores) {
        return leadersOf(epoch);
    }

    /**
     * @notice The top-10 board with scores for ANY epoch (current or past).
     * @dev Boards are epoch-keyed and never cleared, so a closed epoch's final board
     *      and its frozen scores stay readable forever. Unsorted; empty slots are
     *      address(0)/0. Scores are read from that same epoch's points, so a past
     *      board always reports the values it held at settlement.
     * @param epochId The epoch to read (0..current).
     */
    function leadersOf(uint256 epochId)
        public
        view
        returns (address[BOARD_SIZE] memory board, uint256[BOARD_SIZE] memory scores)
    {
        board = _leaders[epochId];
        for (uint256 i; i < BOARD_SIZE; ++i) {
            scores[i] = _points[epochId][board[i]];
        }
    }

    /**
     * @notice Graduation snapshot: holders, cumulative ETH volume, and the mean
     *         daily-close tick over the last ≤7 non-empty days.
     * @dev Walks back at most 7 day-indices from today, averaging only recorded
     *      (traded) days — gap days neither count nor break the walk. Computed
     *      token-side so the registry's graduation check is one external call.
     * @return holders Current unique pool-verified holder count.
     * @return volumeEth Cumulative ETH-equivalent volume (wei).
     * @return meanTick Mean of the recorded daily closes (0 if no data yet).
     * @return daysTracked How many non-empty days entered the mean.
     */
    function graduationStats()
        external
        view
        returns (uint32 holders, uint256 volumeEth, int24 meanTick, uint16 daysTracked)
    {
        holders = holderCount;
        volumeEth = volumeEthCum;

        uint256 today = block.timestamp / 1 days;
        int256 sum;
        uint256 counted;
        for (uint256 i; i < MEAN_TICK_WINDOW; ++i) {
            if (i > today) break; // day-index 0 reached (test chains near genesis)
            DayTick memory day = _dailyTick[today - i];
            if (day.recorded) {
                sum += int256(day.tick);
                ++counted;
            }
        }
        if (counted > 0) meanTick = int24(sum / int256(counted));
        daysTracked = uint16(counted);
    }

    /// @notice A day's closing tick and whether that day traded at all.
    function dailyTickOf(uint256 dayIndex) external view returns (int24 tick, bool recorded) {
        DayTick memory day = _dailyTick[dayIndex];
        return (day.tick, day.recorded);
    }

    /// @notice Whether `account` is currently included in holderCount.
    function isCountedHolder(address account) external view returns (bool) {
        return _counted[account];
    }

    /**
     * @notice Amount of `holder`'s balance that is still movement-locked right now.
     * @dev remaining = total − unlocked(now). Zero for addresses without a lock and
     *      for fully vested locks (the branch in _update then costs one SLOAD).
     */
    function lockRemaining(address holder) public view returns (uint256) {
        Lock memory lock = _locks[holder];
        if (lock.total == 0) return 0;
        return lock.total - _unlockedOf(lock);
    }

    /**
     * @notice Full lock detail for one holder.
     * @return total Locked total (0 = no lock).
     * @return start Lock start timestamp.
     * @return duration Vesting duration (seconds).
     * @return tranches Unlock slice count.
     * @return unlocked Amount vested so far.
     * @return remaining Amount still movement-gated.
     */
    function getLock(address holder)
        external
        view
        returns (uint128 total, uint64 start, uint64 duration, uint32 tranches, uint256 unlocked, uint256 remaining)
    {
        Lock memory lock = _locks[holder];
        unlocked = lock.total == 0 ? 0 : _unlockedOf(lock);
        return (lock.total, lock.start, lock.duration, lock.tranches, unlocked, lock.total - unlocked);
    }

    /**
     * @notice Every lock on this token, for UIs (holders tab lock badges).
     * @dev Bounded at 10 entries by construction, so this is always cheap.
     */
    function getLocks()
        external
        view
        returns (address[] memory holders, uint128[] memory totals, uint256[] memory unlocked, uint256[] memory remaining)
    {
        uint256 count = _lockers.length;
        holders = _lockers;
        totals = new uint128[](count);
        unlocked = new uint256[](count);
        remaining = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            Lock memory lock = _locks[holders[i]];
            totals[i] = lock.total;
            unlocked[i] = _unlockedOf(lock);
            remaining[i] = lock.total - unlocked[i];
        }
    }

    /**
     * @dev Vested amount of a lock at the current timestamp:
     *      total · min(tranches, elapsed·tranches/duration) / tranches, floored.
     *      Integer tranche count first, then the payout — so the curve moves in
     *      discrete slices exactly at each boundary (duration/tranches · k).
     *      All products fit comfortably in 256 bits (128 + 64 + 32 bit inputs).
     */
    function _unlockedOf(Lock memory lock) private view returns (uint256) {
        uint256 elapsed = block.timestamp - lock.start;
        if (elapsed >= lock.duration) return lock.total;
        uint256 vestedTranches = (elapsed * lock.tranches) / lock.duration;
        return (uint256(lock.total) * vestedTranches) / lock.tranches;
    }
}
