// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

/**
 * @title IDiggersRouter
 * @notice Interface of the universal Diggers swap router: a thin ETH<->token trade
 *         wrapper over external AMMs (Uniswap V2, V3 and V4 hookless pools) that skims a
 *         small ETH-side fee to the team treasury. Built to give abandoned "dead
 *         community" tokens a trading home; the first users are the Noxa launcher tokens
 *         rescued onto Diggers, all of which live on Uniswap V3 1% pools.
 * @dev Self-contained (no implementation imports) so indexers/frontends can consume it
 *      standalone. Percentages are ALWAYS 1e18-scaled (1e18 == 100%), never bps.
 * @author BasedDopamine
 */
interface IDiggersRouter {
    // ------------------------------------------------------------------- types

    /// @notice The AMM family a trade routes through. `pool` calldata is an abi-encoded
    ///         pair/pool address for {V2}/{V3}, or an abi-encoded PoolKey for {V4}.
    enum Venue {
        V2,
        V3,
        V4
    }

    // ------------------------------------------------------------------ events

    /// @notice Emitted on every buy and sell, carrying enough post-trade pool state that
    ///         an indexer never needs an RPC follow-up. `sqrtPriceX96After`/`tickAfter`/
    ///         `liquidityAfter` are zero on the V2 leg (V2 has no such state).
    /// @param trader The address that initiated and received the trade.
    /// @param token The non-ETH side of the pair.
    /// @param pool The V2 pair / V3 pool address, or address(0) for V4 (see PoolKey).
    /// @param venue The AMM family used.
    /// @param isBuy True for ETH->token, false for token->ETH.
    /// @param ethGross Total ETH in (buy) or gross ETH out before fee (sell), wei.
    /// @param ethFee Router fee skimmed (wei).
    /// @param ethNet ETH swapped in after fee (buy) or ETH paid to trader (sell), wei.
    /// @param tokenAmount Tokens out (buy) or tokens in (sell).
    /// @param priceEthPerTokenWadAfter Post-trade spot ETH per 1e18 token base units, wad.
    /// @param sqrtPriceX96After Post-trade sqrt price (V3/V4; 0 on V2).
    /// @param tickAfter Post-trade tick (V3/V4; 0 on V2).
    /// @param liquidityAfter Post-trade in-range liquidity (V3/V4; 0 on V2).
    /// @param feeWadUsed The router fee rate applied to this trade (1e18-scaled).
    event Swapped(
        address indexed trader,
        address indexed token,
        address indexed pool,
        uint8 venue,
        bool isBuy,
        uint256 ethGross,
        uint256 ethFee,
        uint256 ethNet,
        uint256 tokenAmount,
        uint256 priceEthPerTokenWadAfter,
        uint160 sqrtPriceX96After,
        int24 tickAfter,
        uint128 liquidityAfter,
        uint256 feeWadUsed
    );

    /// @notice Emitted when accrued ETH fees are swept to the fee recipient.
    event FeeSwept(address indexed to, uint256 amount);

    /// @notice Emitted when the owner changes the fee rate.
    event FeeUpdated(uint256 oldFeeWad, uint256 newFeeWad);

    /// @notice Emitted when the owner rotates the fee recipient.
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);

    /// @notice Emitted on ownership transfer/renounce (newOwner == 0 freezes the fee).
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    // ------------------------------------------------------------------ errors

    /// @notice `deadline` is in the past.
    error Expired();
    /// @notice Realized output fell below the caller's minimum.
    error SlippageExceeded();
    /// @notice The supplied pool/pair is not a canonical factory pool for this token.
    error NoPool();
    /// @notice `venue` is not enabled on this deployment (e.g. V4 without a PoolManager).
    error BadVenue();
    /// @notice `newFeeWad` exceeds the immutable {MAX_FEE_WAD} cap.
    error FeeTooHigh();
    /// @notice Caller is not the current owner.
    error NotOwner();
    /// @notice ETH/token amount of zero supplied where a positive amount is required.
    error ZeroAmount();
    /// @notice A swap callback fired outside of an in-progress router swap, or from an
    ///         address that is not the expected pool.
    error UnauthorizedCallback();
    /// @notice A raw ETH transfer failed.
    error EthTransferFailed();
    /// @notice `receive()` was hit by an address other than WETH or the PoolManager.
    error DirectEthRejected();
    /// @notice A constructor address argument was zero where non-zero is required.
    error ZeroAddress();

    // --------------------------------------------------------------- functions

    /// @notice Buy `token` with ETH, skimming the router fee off `msg.value` first.
    /// @dev `msg.sender` pays the ETH and is recorded as the `trader`; the purchased
    ///      tokens are delivered to `recipient` (pass your own address for a normal buy).
    /// @param token The token to receive.
    /// @param venue AMM family to route through.
    /// @param pool abi-encoded pool/pair address (V2/V3) or PoolKey (V4).
    /// @param minOut Minimum tokens out (slippage floor); reverts below it.
    /// @param deadline Unix seconds after which the trade reverts.
    /// @param recipient Address that receives the purchased tokens (must be non-zero).
    /// @return tokenAmount Tokens delivered to `recipient`.
    function buy(address token, Venue venue, bytes calldata pool, uint256 minOut, uint256 deadline, address recipient)
        external
        payable
        returns (uint256 tokenAmount);

    /// @notice Sell `token` for ETH, skimming the router fee off the ETH output.
    /// @dev Requires a prior ERC20 approval of `amountIn` to this router. `msg.sender`
    ///      supplies the tokens and is recorded as the `trader`; the net ETH is paid to
    ///      `recipient` (pass your own address for a normal sell).
    /// @param token The token to sell.
    /// @param venue AMM family to route through.
    /// @param pool abi-encoded pool/pair address (V2/V3) or PoolKey (V4).
    /// @param amountIn Exact token amount to sell.
    /// @param minOut Minimum ETH out after fee (slippage floor).
    /// @param deadline Unix seconds after which the trade reverts.
    /// @param recipient Address that receives the net ETH (must be non-zero).
    /// @return ethOut ETH paid to `recipient` (net of the router fee).
    function sell(
        address token,
        Venue venue,
        bytes calldata pool,
        uint256 amountIn,
        uint256 minOut,
        uint256 deadline,
        address recipient
    ) external returns (uint256 ethOut);

    /// @notice Sweep all accrued ETH fees to the current {feeRecipient}. Permissionless.
    function sweep() external returns (uint256 amount);

    /// @notice Owner-only: set the fee rate (1e18-scaled), capped at {MAX_FEE_WAD}.
    function setFeeWad(uint256 newFeeWad) external;

    /// @notice Owner-only: rotate the fee recipient (must be non-zero).
    function setFeeRecipient(address newRecipient) external;

    /// @notice Owner-only: hand ownership to `newOwner` (or address(0) to renounce).
    function transferOwnership(address newOwner) external;

    // ---------------------------------------------------------------- views

    /// @notice Current fee rate (1e18-scaled).
    function feeWad() external view returns (uint256);

    /// @notice Immutable maximum fee the owner can ever set (1e18-scaled).
    function MAX_FEE_WAD() external view returns (uint256);

    /// @notice Current owner (address(0) once renounced — fee frozen forever).
    function owner() external view returns (address);

    /// @notice Accrued, unswept ETH fees (wei) = the router's ETH balance at rest.
    function pendingFees() external view returns (uint256);

    /// @notice The V3 pool for (WETH, token, feeTier) per the pinned V3 factory.
    function poolFor(address token, uint24 feeTier) external view returns (address);

    /// @notice Pinned Uniswap V2 factory (address(0) if the V2 leg is disabled).
    function V2_FACTORY() external view returns (address);

    /// @notice Pinned Uniswap V3 factory.
    function V3_FACTORY() external view returns (address);

    /// @notice Pinned Uniswap V4 PoolManager (address(0) if the V4 leg is disabled).
    function POOL_MANAGER() external view returns (address);

    /// @notice Pinned wrapped-native (WETH9) token.
    function WETH() external view returns (address);

    /// @notice Current fee recipient (owner-rotatable pull target for {sweep}).
    function feeRecipient() external view returns (address);
}
