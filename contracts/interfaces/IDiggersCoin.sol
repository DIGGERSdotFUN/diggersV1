// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

/**
 * @title IDiggersCoin
 * @notice Interface of the Diggers platform token: a one-month buy-mining airdrop coin.
 *         During the airdrop window every pool BUY on any Diggers-launched token mints
 *         platform coins to the buyer, priced off the 10% platform slice of that trade's
 *         LP fee. The per-ETH mint rate halves every 7 days. Coins are transfer-locked
 *         until `finalize()`, which pairs 10% of supply with the accrued ETH into a
 *         Uniswap V2 pool (LP burned), mints 50% of the final supply to the team, and
 *         freezes supply forever. Self-contained (no implementation imports).
 * @author BasedDopamine
 */
interface IDiggersCoin {
    // ----------------------------------------------------------------- events

    /// @notice Standard ERC20 transfer event (also emitted for mint/burn legs).
    event Transfer(address indexed from, address indexed to, uint256 value);

    /// @notice Standard ERC20 approval event.
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /// @notice Platform coins minted to a buyer for a pool buy during the airdrop.
    /// @param to Buyer credited with the coins.
    /// @param srcToken The Diggers-launched token whose buy triggered the mint.
    /// @param potEthWei The 10% platform ETH slice of that trade's fee (estimated, wei).
    /// @param minted Coins minted this leg (18 dec).
    /// @param cumMinted Cumulative airdropped coins after this mint.
    /// @param cumPotEth Cumulative estimated platform ETH after this mint.
    event AirdropMinted(
        address indexed to,
        address indexed srcToken,
        uint256 potEthWei,
        uint256 minted,
        uint256 cumMinted,
        uint256 cumPotEth
    );

    /// @notice The airdrop closed: supply frozen, LP paired + burned, team minted.
    /// @param finalSupply Total supply after finalize (airdropped + LP + team).
    /// @param lpTokens Uniswap V2 LP tokens minted and burned to the dead address.
    /// @param lpEth ETH paired into the V2 pool (wei).
    /// @param teamMinted Coins minted to the team treasury.
    event Finalized(uint256 finalSupply, uint256 lpTokens, uint256 lpEth, uint256 teamMinted);

    /// @notice The launchpad owner rotated the team wallet that receives the finalize mint.
    event MintTeamWalletUpdated(address indexed mintTeamWallet);

    // ----------------------------------------------------------------- errors

    /// @notice Sender balance is below the requested amount.
    error BalanceTooLow(uint256 balance, uint256 needed);

    /// @notice Spender allowance is below the requested amount.
    error AllowanceTooLow(uint256 allowance, uint256 needed);

    /// @notice Zero address where a real account is required.
    error ZeroAddress();

    /// @notice Coins cannot move until the airdrop is finalized.
    error TransfersLocked();

    /// @notice `init` was already called (launchpad is fixed forever).
    error AlreadyInitialized();

    /// @notice The launchpad has not been wired in yet (call `init`).
    error NotInitialized();

    /// @notice Caller is not the deployer (init gate).
    error NotDeployer();

    /// @notice Caller is not the launchpad owner (mint-wallet setter gate).
    error NotOwner();

    /// @notice Mint caller is not a token launched by the Diggers launchpad.
    error NotDiggersToken();

    /// @notice The airdrop window has ended — no more minting.
    error AirdropOver();

    /// @notice The airdrop window is still open — cannot finalize yet.
    error AirdropActive();

    /// @notice The airdrop was already finalized.
    error AlreadyFinalized();

    /// @notice A reentrant call into `finalize` was blocked.
    error Reentrancy();

    // ------------------------------------------------------------- lifecycle

    /// @notice Wire in the Diggers launchpad exactly once (deployer-only). Breaks the
    ///         coin<->launchpad circular deploy dependency.
    function init(address diggers) external;

    /// @notice Rotate the team wallet that receives the 50% finalize mint. Gated by the
    ///         launchpad owner; already-minted balances are unaffected.
    function setMintTeamWallet(address newMintTeamWallet) external;

    /// @notice Mint airdrop coins to `to` for a pool buy. Launchpad-token-only; reverts
    ///         after the window. Silently mints nothing on zero/dust input so a buy is
    ///         never bricked. `potEthWei` is the trade's 10% platform fee slice.
    function creditBuy(address to, uint256 potEthWei) external;

    /// @notice Close the airdrop: claim accrued ETH, mint 50% team + 10% LP (paired on
    ///         Uniswap V2 and burned), unlock transfers, freeze supply. Permissionless,
    ///         only after the window ends, once.
    function finalize() external;

    // --------------------------------------------------------------- ERC20

    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external pure returns (uint8);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function burn(uint256 amount) external;

    // ---------------------------------------------------------- immutables

    /// @notice The Diggers launchpad (set once via `init`). Source of truth for the
    ///         owner-controlled airdrop window and the launchpad owner.
    function launchpad() external view returns (address);

    /// @notice Team wallet that receives the 50% team mint at finalize (owner-editable).
    function mintTeamWallet() external view returns (address);

    /// @notice Uniswap V2 Router02 used to seed and burn platform liquidity.
    function V2_ROUTER() external view returns (address);

    /// @notice Whether the airdrop has been finalized (supply frozen, transfers open).
    function finalized() external view returns (bool);

    /// @notice Cumulative coins minted during the airdrop (excludes team + LP mints).
    function airdroppedSupply() external view returns (uint256);

    /// @notice Cumulative estimated platform ETH backing the airdrop (wei).
    function totalPotEthEstimated() external view returns (uint256);

    // ---------------------------------------------------------- projections

    /// @notice Current coins minted per 1 ETH of platform fee (18 dec per 1e18 wei).
    ///         Returns 0 once the window has ended.
    function currentRate() external view returns (uint256);

    /// @notice Projected final supply if the airdrop ended now (2.5x airdropped).
    function projectedFinalSupply() external view returns (uint256);

    /// @notice Implied wei-per-coin at the future LP: realEth / (0.25 * airdropped).
    ///         realEth = coin ETH balance + pending platform ETH owed by the launchpad.
    function impliedPriceWeiPerToken() external view returns (uint256);

    /// @notice ETH value of `user`'s holding at the implied LP price (wei).
    function holdingValueEth(address user) external view returns (uint256);

    /// @notice Seconds left in the airdrop window (0 once ended).
    function airdropSecondsLeft() external view returns (uint256);
}
