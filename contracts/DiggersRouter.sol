// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

/**
 * @title DiggersRouter
 * @notice Universal ETH<->token swap router that skims a small ETH-side fee to the team
 *         treasury. One contract serves every "dead community rescue" regardless of the
 *         AMM the tokens live on: Uniswap V2 pairs, V3 pools, and V4 hookless pools. The
 *         first users are the Noxa launcher tokens rescued onto Diggers (all on V3 1%
 *         pools); the V2 and V4 legs exist for future rescued communities.
 *
 *         The router is deliberately standalone: it shares no state with the Diggers
 *         launchpad or its tokens, holds no positions, and can be abandoned by sweeping
 *         its last fees and pointing the UI elsewhere. Ownership is config-only — the
 *         owner may tune the fee within a hard immutable cap and transfer/renounce, and
 *         has no power over user funds beyond the permissionless treasury sweep.
 * @author BasedDopamine
 */
import {DiggerV4, IPoolManagerLite} from "./libs/DiggerV4.sol";
import {DiggerMath} from "./libs/DiggerMath.sol";
import {IDiggersRouter} from "./interfaces/IDiggersRouter.sol";

/// @dev Wrapped native token (WETH9) surface used for wrap/unwrap and pair transfers.
interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @dev Minimal ERC20 surface the router pulls and pays through.
interface IERC20Min {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @dev Uniswap V3 pool surface: the swap entrypoint plus post-trade state readers.
interface IUniswapV3Pool {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function liquidity() external view returns (uint128);
}

/// @dev Uniswap V3 factory canonical-pool lookup.
interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

/// @dev Uniswap V2 pair surface: reserves + the low-level swap.
interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function token0() external view returns (address);
}

/// @dev Uniswap V2 factory canonical-pair lookup.
interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address);
}

contract DiggersRouter is IDiggersRouter {
    // -------------------------------------------------- constants / immutables

    /// @notice 1e18 == 100%. Fees are 1e18-scaled, never bps.
    uint256 public constant WAD = 1e18;

    /// @notice Hard ceiling the owner can never exceed: 10% (1e18-scaled).
    uint256 public constant MAX_FEE_WAD = 1e17;

    /// @dev V2 pool fee numerator/denominator (0.3% => keep 99.7% of input).
    uint256 private constant V2_FEE_NUM = 997;
    uint256 private constant V2_FEE_DEN = 1000;

    /// @dev EIP-1153 transient slots: a reentrancy latch and the expected V3 callback pool.
    ///      Instance-domained strings keep them distinct from any other deployment lineage.
    bytes32 private constant REENTRANCY_SLOT = keccak256("diggers.router.reentrancy");
    bytes32 private constant V3_CALLBACK_SLOT = keccak256("diggers.router.v3callbackPool");

    /// @notice Pinned Uniswap V2 factory (address(0) disables the V2 leg).
    address public immutable V2_FACTORY;
    /// @notice Pinned Uniswap V3 factory.
    address public immutable V3_FACTORY;
    /// @notice Pinned Uniswap V4 PoolManager (address(0) disables the V4 leg).
    address public immutable POOL_MANAGER;
    /// @notice Pinned wrapped-native token (WETH9).
    address public immutable WETH;

    // ---------------------------------------------------------------- storage

    /// @notice Current fee rate (1e18-scaled). Owner-editable up to {MAX_FEE_WAD}.
    uint256 public feeWad;

    /// @notice Owner-rotatable fee recipient; the permissionless {sweep} target.
    address public feeRecipient;

    /// @notice Config owner. Can edit the fee and transfer/renounce ownership; nothing
    ///         else. address(0) once renounced — the fee is then frozen forever.
    address public owner;

    // ---------------------------------------------------------------- errors

    /// @notice Reentrant entry into a guarded swap.
    error Reentrancy();

    // ------------------------------------------------------------- constructor

    /// @param v3Factory Uniswap V3 factory (required).
    /// @param weth Wrapped-native token (required).
    /// @param feeRecipient_ Initial fee recipient (required; owner-rotatable later).
    /// @param owner_ Initial config owner (may be the deployer).
    /// @param initialFeeWad Launch fee rate (1e18-scaled), must be <= {MAX_FEE_WAD}.
    /// @param v2Factory Uniswap V2 factory, or address(0) to disable the V2 leg.
    /// @param poolManager Uniswap V4 PoolManager, or address(0) to disable the V4 leg.
    constructor(
        address v3Factory,
        address weth,
        address feeRecipient_,
        address owner_,
        uint256 initialFeeWad,
        address v2Factory,
        address poolManager
    ) {
        if (v3Factory == address(0) || weth == address(0) || feeRecipient_ == address(0)) {
            revert ZeroAddress();
        }
        if (initialFeeWad > MAX_FEE_WAD) revert FeeTooHigh();

        V3_FACTORY = v3Factory;
        WETH = weth;
        feeRecipient = feeRecipient_;
        V2_FACTORY = v2Factory;
        POOL_MANAGER = poolManager;
        feeWad = initialFeeWad;
        owner = owner_;

        emit OwnershipTransferred(address(0), owner_);
        emit FeeUpdated(0, initialFeeWad);
        emit FeeRecipientUpdated(address(0), feeRecipient_);
    }

    // ---------------------------------------------------------- receive/fallback

    /// @dev Accept ETH only from WETH (unwrap) and the PoolManager (V4 ETH take).
    receive() external payable {
        if (msg.sender != WETH && msg.sender != POOL_MANAGER) revert DirectEthRejected();
    }

    // ------------------------------------------------------------- modifiers

    modifier nonReentrant() {
        bytes32 slot = REENTRANCY_SLOT;
        uint256 locked;
        assembly {
            locked := tload(slot)
        }
        if (locked != 0) revert Reentrancy();
        assembly {
            tstore(slot, 1)
        }
        _;
        assembly {
            tstore(slot, 0)
        }
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ----------------------------------------------------------- external: trade

    /// @notice Buy `token` with ETH, skimming the router fee off `msg.value` first.
    ///         `msg.sender` pays the ETH and is recorded as the `trader`; the purchased
    ///         tokens are delivered to `recipient`. Routes through V2, V3, or V4 depending
    ///         on `venue`. Reverts if output < `minOut` or `deadline` expired.
    /// @param token The token to receive.
    /// @param venue AMM family to route through (V2/V3/V4).
    /// @param pool abi-encoded pool/pair address (V2/V3) or PoolKey (V4).
    /// @param minOut Minimum tokens out (slippage floor).
    /// @param deadline Unix seconds after which the trade reverts.
    /// @param recipient Address that receives the purchased tokens (must be non-zero).
    /// @return tokenAmount Tokens delivered to `recipient`.
    function buy(address token, Venue venue, bytes calldata pool, uint256 minOut, uint256 deadline, address recipient)
        external
        payable
        nonReentrant
        returns (uint256 tokenAmount)
    {
        if (block.timestamp > deadline) revert Expired();
        if (msg.value == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();

        uint256 fee = (msg.value * feeWad) / WAD;
        uint256 ethIn = msg.value - fee;

        address poolAddr;
        uint160 sqrtAfter;
        int24 tickAfter;
        uint128 liqAfter;
        uint256 priceWad;

        if (venue == Venue.V3) {
            poolAddr = _decodeAddress(pool);
            _verifyV3Pool(poolAddr, token);
            bool zeroForOne = WETH < token; // WETH is the input currency
            IWETH9(WETH).deposit{value: ethIn}();
            tokenAmount = _v3Swap(poolAddr, token, zeroForOne, ethIn, recipient);
            (sqrtAfter, tickAfter, liqAfter, priceWad) = _v3State(poolAddr, WETH < token);
        } else if (venue == Venue.V2) {
            poolAddr = _decodeAddress(pool);
            _verifyV2Pair(poolAddr, token);
            IWETH9(WETH).deposit{value: ethIn}();
            (tokenAmount, priceWad) = _v2Swap(poolAddr, WETH, ethIn, recipient);
        } else {
            // V4: ETH (currency0) in, token (currency1) out.
            IPoolManagerLite.PoolKey memory key = _verifyV4Key(pool, token);
            tokenAmount = _v4Swap(key, true, ethIn, recipient);
            (sqrtAfter, tickAfter, liqAfter, priceWad) = _v4State(key);
            poolAddr = address(0);
        }

        if (tokenAmount < minOut) revert SlippageExceeded();

        emit Swapped(
            msg.sender,
            token,
            poolAddr,
            uint8(venue),
            true,
            msg.value,
            fee,
            ethIn,
            tokenAmount,
            priceWad,
            sqrtAfter,
            tickAfter,
            liqAfter,
            feeWad
        );
    }

    /// @notice Sell `token` for ETH, skimming the router fee off the ETH output.
    ///         Requires a prior ERC-20 approval of `amountIn` to this router. `msg.sender`
    ///         supplies the tokens and is recorded as the `trader`; the net ETH (after fee)
    ///         is paid to `recipient`. Reverts if output < `minOut` or `deadline` expired.
    /// @param token The token to sell.
    /// @param venue AMM family to route through (V2/V3/V4).
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
    ) external nonReentrant returns (uint256 ethOut) {
        if (block.timestamp > deadline) revert Expired();
        if (amountIn == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();

        // Pull the tokens to sell (requires prior approval to this router).
        if (!IERC20Min(token).transferFrom(msg.sender, address(this), amountIn)) revert ZeroAmount();

        address poolAddr;
        uint160 sqrtAfter;
        int24 tickAfter;
        uint128 liqAfter;
        uint256 priceWad;
        uint256 ethGross;

        if (venue == Venue.V3) {
            poolAddr = _decodeAddress(pool);
            _verifyV3Pool(poolAddr, token);
            bool zeroForOne = token < WETH; // token is the input currency
            uint256 wethOut = _v3Swap(poolAddr, token, zeroForOne, amountIn, address(this));
            IWETH9(WETH).withdraw(wethOut);
            ethGross = wethOut;
            (sqrtAfter, tickAfter, liqAfter, priceWad) = _v3State(poolAddr, WETH < token);
        } else if (venue == Venue.V2) {
            poolAddr = _decodeAddress(pool);
            _verifyV2Pair(poolAddr, token);
            uint256 wethOut;
            (wethOut, priceWad) = _v2Swap(poolAddr, token, amountIn, address(this));
            IWETH9(WETH).withdraw(wethOut);
            ethGross = wethOut;
        } else {
            // V4: token (currency1) in, ETH (currency0) out.
            IPoolManagerLite.PoolKey memory key = _verifyV4Key(pool, token);
            ethGross = _v4Swap(key, false, amountIn, address(this));
            (sqrtAfter, tickAfter, liqAfter, priceWad) = _v4State(key);
            poolAddr = address(0);
        }

        uint256 fee = (ethGross * feeWad) / WAD;
        ethOut = ethGross - fee;
        if (ethOut < minOut) revert SlippageExceeded();

        _sendEth(recipient, ethOut);

        emit Swapped(
            msg.sender,
            token,
            poolAddr,
            uint8(venue),
            false,
            ethGross,
            fee,
            ethOut,
            amountIn,
            priceWad,
            sqrtAfter,
            tickAfter,
            liqAfter,
            feeWad
        );
    }

    // ------------------------------------------------------------- swap callbacks

    /// @notice Uniswap V3 swap callback: pay the pool the input it is owed.
    /// @dev Fires only during a router-initiated V3 swap. The expected pool is stashed in
    ///      transient storage by {_v3Swap}; any other caller (or a stray direct call)
    ///      reverts. The router pays from its own balance (wrapped ETH on a buy, the
    ///      pulled token on a sell), so a spoofed callback could never drain it anyway.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        bytes32 slot = V3_CALLBACK_SLOT;
        address expected;
        assembly {
            expected := tload(slot)
        }
        if (expected == address(0) || msg.sender != expected) revert UnauthorizedCallback();

        // Pay whichever side is owed (positive delta), in that side's pool currency.
        if (amount0Delta > 0) {
            _payPool(msg.sender, IUniswapV3Pool(msg.sender).token0(), uint256(amount0Delta));
        } else if (amount1Delta > 0) {
            _payPool(msg.sender, IUniswapV3Pool(msg.sender).token1(), uint256(amount1Delta));
        }
        // silence unused warning on data (bound token is derivable from the pool)
        data;
    }

    /// @notice Uniswap V4 unlock callback: run the swap, settle input, take output.
    /// @dev Only the PoolManager may call. Mirrors the launchpad's proven unlock/settle/
    ///      take sequence; ETH (currency0) settles with value, the ERC20 side syncs +
    ///      transfers + settles, and the output is taken straight to the recipient.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != POOL_MANAGER) revert UnauthorizedCallback();

        (IPoolManagerLite.PoolKey memory key, bool zeroForOne, uint256 amountIn, address recipient) =
            abi.decode(data, (IPoolManagerLite.PoolKey, bool, uint256, address));

        uint160 limit = zeroForOne ? DiggerV4.MIN_SQRT_RATIO + 1 : DiggerV4.MAX_SQRT_RATIO - 1;
        IPoolManagerLite.SwapParams memory params =
            IPoolManagerLite.SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: limit});

        int256 swapDelta = IPoolManagerLite(POOL_MANAGER).swap(key, params, "");
        (int128 delta0, int128 delta1) = _splitDelta(swapDelta);

        if (delta0 < 0) _settleV4(key.currency0, uint256(uint128(-delta0)));
        if (delta1 < 0) _settleV4(key.currency1, uint256(uint128(-delta1)));
        if (delta0 > 0) IPoolManagerLite(POOL_MANAGER).take(key.currency0, recipient, uint256(uint128(delta0)));
        if (delta1 > 0) IPoolManagerLite(POOL_MANAGER).take(key.currency1, recipient, uint256(uint128(delta1)));

        return abi.encode(delta0, delta1);
    }

    // ------------------------------------------------------------- external: admin

    /// @notice Sweep all accrued ETH fees to the current `feeRecipient`. Permissionless —
    ///         anyone may call.
    /// @return amount ETH swept (wei).
    function sweep() external returns (uint256 amount) {
        amount = address(this).balance;
        if (amount == 0) return 0;
        address to = feeRecipient;
        _sendEth(to, amount);
        emit FeeSwept(to, amount);
    }

    /// @notice Owner-only: set the fee rate (1e18-scaled), capped at `MAX_FEE_WAD`.
    function setFeeWad(uint256 newFeeWad) external onlyOwner {
        if (newFeeWad > MAX_FEE_WAD) revert FeeTooHigh();
        uint256 old = feeWad;
        feeWad = newFeeWad;
        emit FeeUpdated(old, newFeeWad);
    }

    /// @notice Owner-only: rotate the fee recipient (must be non-zero).
    function setFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert ZeroAddress();
        address old = feeRecipient;
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(old, newRecipient);
    }

    /// @notice Owner-only: hand ownership to `newOwner` (or address(0) to renounce —
    ///         freezes the fee forever).
    function transferOwnership(address newOwner) external onlyOwner {
        address old = owner;
        owner = newOwner;
        emit OwnershipTransferred(old, newOwner);
    }

    // ---------------------------------------------------------------- views

    /// @notice Accrued, unswept ETH fees (wei) = the router's ETH balance at rest.
    function pendingFees() external view returns (uint256) {
        return address(this).balance;
    }

    /// @notice The canonical V3 pool for (WETH, `token`, `feeTier`) per the pinned factory.
    function poolFor(address token, uint24 feeTier) external view returns (address) {
        return IUniswapV3Factory(V3_FACTORY).getPool(WETH, token, feeTier);
    }

    // ---------------------------------------------------------- internal: V3

    /// @dev Initiate a V3 exact-input swap; the callback pays the pool. Output measured
    ///      from the returned deltas. `recipient` receives the output currency directly.
    function _v3Swap(address pool, address token, bool zeroForOne, uint256 amountIn, address recipient)
        internal
        returns (uint256 amountOut)
    {
        bytes32 slot = V3_CALLBACK_SLOT;
        assembly {
            tstore(slot, pool)
        }

        uint160 limit = zeroForOne ? DiggerV4.MIN_SQRT_RATIO + 1 : DiggerV4.MAX_SQRT_RATIO - 1;
        (int256 amount0, int256 amount1) =
            IUniswapV3Pool(pool).swap(recipient, zeroForOne, int256(amountIn), limit, abi.encode(token));

        assembly {
            tstore(slot, 0)
        }

        int256 out = zeroForOne ? amount1 : amount0;
        amountOut = out < 0 ? uint256(-out) : 0;
    }

    /// @dev Verify `pool` is the canonical V3 pool for (WETH, token) at its own fee tier.
    function _verifyV3Pool(address pool, address token) internal view {
        if (pool == address(0) || pool.code.length == 0) revert NoPool();
        uint24 poolFee = IUniswapV3Pool(pool).fee();
        if (IUniswapV3Factory(V3_FACTORY).getPool(WETH, token, poolFee) != pool) revert NoPool();
    }

    /// @dev Post-swap V3 state for the event: sqrtPrice, tick, liquidity, spot price wad.
    function _v3State(address pool, bool wethIsToken0)
        internal
        view
        returns (uint160 sqrtAfter, int24 tickAfter, uint128 liqAfter, uint256 priceWad)
    {
        (sqrtAfter, tickAfter,,,,,) = IUniswapV3Pool(pool).slot0();
        liqAfter = IUniswapV3Pool(pool).liquidity();
        priceWad = _priceEthPerTokenWad(sqrtAfter, wethIsToken0);
    }

    /// @dev Pay `amount` of `currency` from the router's balance to the calling pool.
    function _payPool(address pool, address currency, uint256 amount) internal {
        if (!IERC20Min(currency).transfer(pool, amount)) revert EthTransferFailed();
    }

    // ---------------------------------------------------------- internal: V2

    /// @dev Constant-product swap on a V2 pair. `tokenIn`/`tokenOut` are WETH/token in the
    ///      order of the trade. Transfers the input to the pair, then pulls the output.
    function _v2Swap(address pair, address tokenIn, uint256 amountIn, address recipient)
        internal
        returns (uint256 amountOut, uint256 priceWad)
    {
        (uint112 r0, uint112 r1,) = IUniswapV2Pair(pair).getReserves();
        address t0 = IUniswapV2Pair(pair).token0();
        (uint256 reserveIn, uint256 reserveOut) = tokenIn == t0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        if (reserveIn == 0 || reserveOut == 0) revert NoPool();

        uint256 amountInWithFee = amountIn * V2_FEE_NUM;
        amountOut = (amountInWithFee * reserveOut) / (reserveIn * V2_FEE_DEN + amountInWithFee);
        if (amountOut == 0) revert SlippageExceeded();

        if (!IERC20Min(tokenIn).transfer(pair, amountIn)) revert EthTransferFailed();
        (uint256 amount0Out, uint256 amount1Out) =
            tokenIn == t0 ? (uint256(0), amountOut) : (amountOut, uint256(0));
        IUniswapV2Pair(pair).swap(amount0Out, amount1Out, recipient, "");

        // Post-swap spot: WETH reserve * 1e18 / token reserve (raw, 18-assumed).
        (uint112 a0, uint112 a1,) = IUniswapV2Pair(pair).getReserves();
        address weth = WETH;
        (uint256 resWeth, uint256 resToken) =
            weth == t0 ? (uint256(a0), uint256(a1)) : (uint256(a1), uint256(a0));
        priceWad = resToken == 0 ? 0 : (resWeth * WAD) / resToken;
    }

    /// @dev Verify `pair` is the canonical V2 pair for (WETH, token). Reverts if the V2
    ///      leg is disabled (no factory pinned).
    function _verifyV2Pair(address pair, address token) internal view {
        if (V2_FACTORY == address(0)) revert BadVenue();
        if (pair == address(0)) revert NoPool();
        if (IUniswapV2Factory(V2_FACTORY).getPair(WETH, token) != pair) revert NoPool();
    }

    // ---------------------------------------------------------- internal: V4

    /// @dev Validate + decode the user-supplied V4 pool key. The leg must be enabled,
    ///      ETH must be currency0, `token` must be currency1 (so the Swapped event can
    ///      never carry a token that differs from the pool actually traded — indexer
    ///      poisoning), and the pool must be hookless (router scope, and a hook contract
    ///      is an arbitrary-code re-entry surface we refuse to touch).
    function _verifyV4Key(bytes calldata pool, address token)
        internal
        view
        returns (IPoolManagerLite.PoolKey memory key)
    {
        if (POOL_MANAGER == address(0)) revert BadVenue();
        key = _decodePoolKey(pool);
        if (key.currency0 != address(0) || key.currency1 != token || key.hooks != address(0)) {
            revert NoPool();
        }
    }

    /// @dev Initiate a V4 swap through the PoolManager unlock. Output measured from the
    ///      returned deltas; settlement rides the router balance inside the callback.
    function _v4Swap(IPoolManagerLite.PoolKey memory key, bool zeroForOne, uint256 amountIn, address recipient)
        internal
        returns (uint256 amountOut)
    {
        bytes memory answer =
            IPoolManagerLite(POOL_MANAGER).unlock(abi.encode(key, zeroForOne, amountIn, recipient));
        (int128 delta0, int128 delta1) = abi.decode(answer, (int128, int128));
        int128 out = zeroForOne ? delta1 : delta0;
        amountOut = out > 0 ? uint256(uint128(out)) : 0;
    }

    /// @dev Post-swap V4 state for the event.
    function _v4State(IPoolManagerLite.PoolKey memory key)
        internal
        view
        returns (uint160 sqrtAfter, int24 tickAfter, uint128 liqAfter, uint256 priceWad)
    {
        bytes32 poolId = keccak256(abi.encode(key));
        DiggerV4.Slot0 memory s = DiggerV4.getSlot0(POOL_MANAGER, poolId);
        sqrtAfter = s.sqrtPriceX96;
        tickAfter = s.tick;
        liqAfter = DiggerV4.getPoolLiquidity(POOL_MANAGER, poolId);
        // ETH is currency0 in V4 pools, so WETH-as-token0 semantics apply for pricing.
        priceWad = _priceEthPerTokenWad(sqrtAfter, true);
    }

    /// @dev Pay a negative V4 delta to the PoolManager (ETH via value; ERC20 via
    ///      sync -> transfer -> settle).
    function _settleV4(address currency, uint256 amount) internal {
        if (currency == address(0)) {
            IPoolManagerLite(POOL_MANAGER).settle{value: amount}();
        } else {
            IPoolManagerLite(POOL_MANAGER).sync(currency);
            if (!IERC20Min(currency).transfer(POOL_MANAGER, amount)) revert EthTransferFailed();
            IPoolManagerLite(POOL_MANAGER).settle();
        }
    }

    /// @dev Split a packed V4 BalanceDelta: currency0 high 128 bits, currency1 low 128.
    function _splitDelta(int256 delta) internal pure returns (int128 amount0, int128 amount1) {
        assembly {
            amount0 := sar(128, delta)
            amount1 := signextend(15, delta)
        }
    }

    // ------------------------------------------------------------- internal: misc

    /// @dev Spot ETH per 1e18 token base units (wad), from a sqrt price. Raw (assumes
    ///      18-dec tokens); off-chain consumers decimal-adjust for display.
    function _priceEthPerTokenWad(uint160 sqrtPriceX96, bool wethIsToken0) internal pure returns (uint256) {
        if (sqrtPriceX96 == 0) return 0;
        uint256 sp = uint256(sqrtPriceX96);
        if (wethIsToken0) {
            // WETH is token0: ETH per token = (2^96 / sqrtP)^2, scaled by 1e18.
            uint256 r = DiggerMath.md512(WAD, DiggerV4.Q96, sp);
            return DiggerMath.md512(r, DiggerV4.Q96, sp);
        } else {
            // WETH is token1: ETH per token = (sqrtP / 2^96)^2, scaled by 1e18.
            uint256 r = DiggerMath.md512(WAD, sp, DiggerV4.Q96);
            return DiggerMath.md512(r, sp, DiggerV4.Q96);
        }
    }

    /// @dev Decode an abi-encoded single address (V2/V3 `pool` calldata).
    function _decodeAddress(bytes calldata data) internal pure returns (address) {
        return abi.decode(data, (address));
    }

    /// @dev Decode an abi-encoded V4 PoolKey (`pool` calldata on the V4 leg).
    function _decodePoolKey(bytes calldata data) internal pure returns (IPoolManagerLite.PoolKey memory) {
        return abi.decode(data, (IPoolManagerLite.PoolKey));
    }

    /// @dev Send raw ETH, bubbling a clean error on failure.
    function _sendEth(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }
}
