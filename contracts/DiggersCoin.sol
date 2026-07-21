// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

/**
 * @title DiggersCoin
 * @notice The Diggers platform token — a one-month buy-mining airdrop coin.
 *
 *         For the first 30 days after deployment, every pool BUY on any Diggers-launched
 *         token mints platform coins to the buyer. The mint is priced off the 10% platform
 *         slice of that trade's LP fee (the same slice `Diggers.harvest` routes to this
 *         contract's pull-payment ledger), so coins are only ever minted against real
 *         protocol revenue. The mint is driven from `DiggersToken._update`, NOT the router,
 *         so it fires even on direct Uniswap trades.
 *
 *         The per-ETH mint rate starts at 100,000 coins / ETH (10,000 coins / 0.1 ETH) and
 *         HALVES every 7 days: 100k -> 50k -> 25k -> 12.5k -> 6.25k. Coins are
 *         transfer-locked for the whole window; holders can watch their projected value
 *         via the view functions but cannot move coins until `finalize()`.
 *
 *         `finalize()` (permissionless, after the window) claims the accrued platform ETH,
 *         mints 10% of the final supply as LP and pairs it with ALL that ETH on Uniswap V2
 *         (the LP tokens are burned to the dead address, so protocol liquidity is
 *         permanent), mints 50% of the final supply to the team treasury, unlocks
 *         transfers, and freezes supply forever. Final split: 40% airdrop / 10% LP / 50%
 *         team, where the absolute supply is entirely demand-driven.
 *
 * @dev Non-mintable after `finalize()`. The launchpad address is wired once via `init` to
 *      break the coin<->launchpad circular deploy dependency (deploy coin, deploy Diggers
 *      with the coin address, then `init(diggers)` before the first `create`).
 * @author BasedDopamine
 */
import {DiggerMath} from "./libs/DiggerMath.sol";
import {IDiggers} from "./interfaces/IDiggers.sol";
import {IDiggersCoin} from "./interfaces/IDiggersCoin.sol";

/// @notice Minimal slice of the Uniswap V2 Router02 ABI used at finalize.
interface IUniswapV2Router02 {
    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);
}

contract DiggersCoin is IDiggersCoin {
    // -------------------------------------------------- constants / immutables

    /// @dev 1e18 == 100%. Percentages are ALWAYS 1e18-scaled here.
    uint256 private constant WAD = 1e18;

    /// @dev Week-0 mint rate: 100,000 coins per 1 ETH of platform fee (10,000 per 0.1
    ///      ETH). Halved each 7-day week via a right shift. Expressed as coins (18 dec)
    ///      per 1e18 wei, so `minted = potEthWei * (RATE >> week) / 1e18`.
    uint256 private constant RATE_NUMERATOR = 100_000e18;

    /// @dev One halving step (seconds).
    uint256 private constant WEEK = 7 days;

    /// @dev LP allocation: 10% of final supply == 25% of the airdropped amount.
    ///      teamMint = 125% of airdropped; lpMint = 25% of airdropped; finalSupply = 250%.
    uint256 private constant TEAM_NUM = 125;
    uint256 private constant LP_NUM = 25;
    uint256 private constant PCT = 100;

    /// @dev Burn sink for the V2 LP tokens — liquidity is permanent.
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /// @dev EIP-1153 transient reentrancy latch for `finalize` (the external-call path).
    ///      Redundant with the `finalized` flag set before any external call; kept as an
    ///      explicit belt-and-suspenders guard. Auto-clears at tx end.
    bytes32 private constant REENTRANCY_SLOT = keccak256("diggerscoin.reentrancy.lock");

    /// @notice Uniswap V2 Router02 used to seed and burn platform liquidity.
    address public immutable V2_ROUTER;

    /// @dev Deployer — the only address allowed to wire in the launchpad.
    address private immutable _deployer;

    // ---------------------------------------------------------------- storage

    /// @notice The Diggers launchpad (set once via `init`). Source of truth for the
    ///         owner-controlled airdrop window (`airdropStart`/`airdropEnd`) and owner.
    address public launchpad;

    /// @notice Team wallet that receives the 50% team mint at finalize. Owner-editable
    ///         (gated by the launchpad owner); already-minted balances are unaffected.
    address public mintTeamWallet;

    /// @notice Whether the airdrop has been finalized (supply frozen, transfers open).
    bool public finalized;

    /// @notice Cumulative coins minted during the airdrop (excludes team + LP).
    uint256 public airdroppedSupply;

    /// @notice Cumulative estimated platform ETH backing the airdrop (wei).
    uint256 public totalPotEthEstimated;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;

    // ------------------------------------------------------------ constructor

    /**
     * @notice Deploys the platform coin. The airdrop window is owner-controlled and lives
     *         on the launchpad; it opens only when the owner calls `startAirdrop` there.
     * @param mintTeamWallet_ Initial recipient of the 50% team mint at finalize (non-zero).
     * @param v2Router Uniswap V2 Router02 for the finalize LP pairing (non-zero).
     */
    constructor(address mintTeamWallet_, address v2Router) {
        if (mintTeamWallet_ == address(0) || v2Router == address(0)) revert ZeroAddress();
        mintTeamWallet = mintTeamWallet_;
        V2_ROUTER = v2Router;
        _deployer = msg.sender;
    }

    /// @dev Accepts the platform ETH slice pulled from the launchpad during finalize.
    receive() external payable {}

    // ------------------------------------------------------------- lifecycle

    /// @notice Wire in the Diggers launchpad exactly once (deployer-only). Breaks the
    ///         coin<->launchpad circular deploy dependency: deploy coin, deploy Diggers
    ///         with the coin address, then call `init(diggers)` before the first `create`.
    function init(address diggers) external {
        if (msg.sender != _deployer) revert NotDeployer();
        if (launchpad != address(0)) revert AlreadyInitialized();
        if (diggers == address(0)) revert ZeroAddress();
        launchpad = diggers;
    }

    /// @notice Rotate the team wallet that receives the 50% finalize mint. Gated by the
    ///         launchpad owner; already-minted balances are unaffected.
    function setMintTeamWallet(address newMintTeamWallet) external {
        address pad = launchpad;
        if (pad == address(0)) revert NotInitialized();
        if (msg.sender != IDiggers(pad).owner()) revert NotOwner();
        if (newMintTeamWallet == address(0)) revert ZeroAddress();
        mintTeamWallet = newMintTeamWallet;
        emit MintTeamWalletUpdated(newMintTeamWallet);
    }

    /// @notice Mint airdrop coins to `to` for a pool buy. Only callable by a token
    ///         launched through the Diggers launchpad; reverts after the airdrop window.
    ///         Silently mints nothing on zero/dust input so a buy is never bricked.
    ///         `potEthWei` is the trade's 10% platform fee slice (estimated, wei).
    function creditBuy(address to, uint256 potEthWei) external {
        address pad = launchpad;
        if (pad == address(0)) revert NotInitialized();
        if (!IDiggers(pad).isDiggersToken(msg.sender)) revert NotDiggersToken();
        if (!IDiggers(pad).airdropActive()) revert AirdropOver();

        // Silent no-op so a dust buy can never brick the carrying trade: the token hook
        // passes `feeEthEst / 10`, which floors to 0 for tiny trades. (For any potEthWei >= 1
        // the in-window rate >= 6250e18 mints >= 6250, so `minted == 0` iff `potEthWei == 0`.)
        uint256 minted = DiggerMath.md512(potEthWei, _weekRate(), WAD);
        if (minted == 0) return;

        airdroppedSupply += minted;
        totalPotEthEstimated += potEthWei;
        _update(address(0), to, minted);

        emit AirdropMinted(to, msg.sender, potEthWei, minted, airdroppedSupply, totalPotEthEstimated);
    }

    /// @dev Transient reentrancy latch. Redundant with the `finalized` flag but explicit.
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

    /// @notice Close the airdrop: claim accrued ETH from the launchpad, mint 50% of
    ///         final supply to the team treasury and 10% as LP (paired with all accrued
    ///         ETH on Uniswap V2; LP tokens burned to the dead address for permanent
    ///         liquidity), unlock transfers, and freeze supply forever. Permissionless,
    ///         once only, after the airdrop window has fully elapsed.
    function finalize() external nonReentrant {
        address pad = launchpad;
        if (pad == address(0)) revert NotInitialized();
        // The window must have been started AND fully elapsed. Before start airdropEnd is
        // 0, so `airdropActive()` is false but the window never ran — block that too.
        if (IDiggers(pad).airdropStart() == 0 || block.timestamp < IDiggers(pad).airdropEnd()) {
            revert AirdropActive();
        }
        if (finalized) revert AlreadyFinalized();

        // CEI: freeze + unlock BEFORE any external call. A reentrant finalize reverts
        // AlreadyFinalized; the mints below run with from == address(0) (always allowed).
        finalized = true;

        // Pull the platform ETH slice. `claim` reverts on a zero balance, so gate it.
        if (IDiggers(launchpad).ethOwed(address(this)) > 0) {
            IDiggers(launchpad).claim();
        }
        uint256 lpEth = address(this).balance;

        uint256 airdropped = airdroppedSupply;
        uint256 teamMinted;
        uint256 lpTokens;
        if (airdropped > 0) {
            teamMinted = airdropped * TEAM_NUM / PCT; // 125% of airdropped == 50% of final
            uint256 lpMint = airdropped * LP_NUM / PCT; // 25% of airdropped == 10% of final

            _update(address(0), mintTeamWallet, teamMinted);
            _update(address(0), address(this), lpMint);

            if (lpEth > 0) {
                _allowances[address(this)][V2_ROUTER] = lpMint;
                emit Approval(address(this), V2_ROUTER, lpMint);
                (,, lpTokens) = IUniswapV2Router02(V2_ROUTER).addLiquidityETH{value: lpEth}(
                    address(this), lpMint, 0, 0, DEAD, block.timestamp
                );
            }
            // If lpEth == 0 the LP mint stays on this contract with no mover — the tokens
            // are permanently frozen, so the 250% supply proportions are still exact.
        }

        emit Finalized(_totalSupply, lpTokens, lpEth, teamMinted);
    }

    // --------------------------------------------------------------- ERC20

    /// @notice Standard ERC-20 transfer. Reverts `TransfersLocked` until finalized.
    function transfer(address to, uint256 amount) external returns (bool) {
        if (to == address(0)) revert ZeroAddress();
        _update(msg.sender, to, amount);
        return true;
    }

    /// @notice Standard ERC-20 approval.
    function approve(address spender, uint256 amount) external returns (bool) {
        if (spender == address(0)) revert ZeroAddress();
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /// @notice Standard ERC-20 transferFrom with allowance check. Infinite allowance
    ///         (`type(uint256).max`) skips deduction. Reverts `TransfersLocked` until
    ///         finalized.
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (to == address(0)) revert ZeroAddress();
        uint256 allowed = _allowances[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert AllowanceTooLow(allowed, amount);
            unchecked {
                _allowances[from][msg.sender] = allowed - amount;
            }
        }
        _update(from, to, amount);
        return true;
    }

    /// @notice Burns `amount` from the caller, reducing total supply forever.
    function burn(uint256 amount) external {
        _update(msg.sender, address(0), amount);
    }

    // ----------------------------------------------------------------- internal

    /// @dev Single movement pipeline. Mints (from == 0) are always allowed; every other
    ///      movement (transfer, transferFrom, burn) is locked until `finalized`.
    function _update(address from, address to, uint256 amount) private {
        if (from != address(0) && !finalized) revert TransfersLocked();

        if (from == address(0)) {
            _totalSupply += amount;
        } else {
            uint256 bal = _balances[from];
            if (bal < amount) revert BalanceTooLow(bal, amount);
            unchecked {
                _balances[from] = bal - amount;
            }
        }

        if (to == address(0)) {
            unchecked {
                _totalSupply -= amount;
            }
        } else {
            unchecked {
                _balances[to] += amount;
            }
        }

        emit Transfer(from, to, amount);
    }

    /// @dev Coins per 1e18 wei of platform fee at the current time, halved per week.
    ///      Only called while the window is open, so the shift is bounded (week <= 4).
    ///      Reads the owner-controlled window start from the launchpad.
    function _weekRate() private view returns (uint256) {
        uint256 wk = (block.timestamp - IDiggers(launchpad).airdropStart()) / WEEK;
        return RATE_NUMERATOR >> wk;
    }

    // -------------------------------------------------------------------- views

    /// @notice Returns the token name: "Diggers".
    function name() external pure returns (string memory) {
        return "Diggers";
    }

    /// @notice Returns the token symbol: "DIG".
    function symbol() external pure returns (string memory) {
        return "DIG";
    }

    /// @notice Returns 18 decimals.
    function decimals() external pure returns (uint8) {
        return 18;
    }

    /// @notice Current total supply (grows during airdrop minting and finalize; decreases on burns).
    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    /// @notice Token balance of `account`.
    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    /// @notice Remaining allowance that `spender` may transfer from `owner`.
    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }

    /// @notice Current coins minted per 1 ETH of platform fee (18 dec per 1e18 wei).
    ///         Halves every 7 days: 100k → 50k → 25k → 12.5k → 6.25k. Returns 0 after
    ///         the airdrop window ends.
    function currentRate() external view returns (uint256) {
        address pad = launchpad;
        if (pad == address(0) || !IDiggers(pad).airdropActive()) return 0;
        return _weekRate();
    }

    /// @notice Projected final supply if the airdrop ended now: airdropped × 2.5
    ///         (40% airdrop / 10% LP / 50% team).
    function projectedFinalSupply() external view returns (uint256) {
        return airdroppedSupply * (TEAM_NUM + LP_NUM + PCT) / PCT; // airdropped * 2.5
    }

    /// @notice Implied wei-per-coin at the future LP price: realEth / (0.25 × airdropped).
    ///         `realEth` = this contract's ETH balance + pending platform ETH owed by the
    ///         launchpad. Returns 0 if no supply has been airdropped yet.
    function impliedPriceWeiPerToken() public view returns (uint256) {
        uint256 lpAlloc = airdroppedSupply * LP_NUM / PCT; // 0.25 * airdropped
        if (lpAlloc == 0) return 0;
        uint256 realEth = address(this).balance;
        address pad = launchpad;
        if (pad != address(0)) realEth += IDiggers(pad).ethOwed(address(this));
        return DiggerMath.md512(realEth, WAD, lpAlloc);
    }

    /// @notice ETH value of `user`'s holding at the implied LP price (wei).
    function holdingValueEth(address user) external view returns (uint256) {
        return DiggerMath.md512(_balances[user], impliedPriceWeiPerToken(), WAD);
    }

    /// @notice Seconds remaining in the airdrop window. Returns 0 if the launchpad is not
    ///         initialized, the airdrop has not started, or it has already ended.
    function airdropSecondsLeft() external view returns (uint256) {
        address pad = launchpad;
        if (pad == address(0)) return 0;
        uint64 end = IDiggers(pad).airdropEnd();
        if (end == 0 || block.timestamp >= end) return 0;
        return uint256(end) - block.timestamp;
    }
}
