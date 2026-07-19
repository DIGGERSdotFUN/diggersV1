// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {DiggerMath} from "./DiggerMath.sol";
import {DiggerLaunchLiquidity} from "./DiggerLaunchLiquidity.sol";

/**
 * @title DiggerV4
 * @notice Compact Uniswap V4 integration for the Diggers launchpad: a minimal
 *         PoolManager interface, a stateless library (tick math, price conversion,
 *         liquidity math, extsload state readers, an exact-input quoter), and an
 *         abstract callback base implementing the unlock pattern for add-liquidity,
 *         fee collection, and exact-input swaps. Scope is deliberately narrow:
 *         hookless ETH/TOKEN pools only, ETH always currency0, no multi-hop, no
 *         position NFTs, and NO liquidity-removal path — Diggers positions are
 *         permanent, so the code to unwind them does not exist.
 * @author BasedDopamine
 */

/// @notice Minimal slice of the V4 PoolManager ABI used by Diggers. Struct shapes are
///         canonical Uniswap layouts — poolId = keccak256(abi.encode(PoolKey)).
interface IPoolManagerLite {
    /// @dev Uniquely identifies a pool.
    struct PoolKey {
        // Lower-sorted currency; always native ETH (address(0)) in Diggers pools
        address currency0;
        // Higher-sorted currency; the launched ERC20
        address currency1;
        // LP fee in millionths (10000 = 1%)
        uint24 fee;
        // Tick granularity for positions in this pool
        int24 tickSpacing;
        // Hook contract; always address(0) in Diggers pools
        address hooks;
    }

    /// @dev Arguments to modifyLiquidity. Positive delta mints, zero flushes fees.
    struct ModifyLiquidityParams {
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
        // Distinguishes positions of the same owner/range
        bytes32 salt;
    }

    /// @dev Arguments to swap. Negative amountSpecified = exact input.
    struct SwapParams {
        bool zeroForOne;
        int256 amountSpecified;
        // Price bound at which the swap halts
        uint160 sqrtPriceLimitX96;
    }

    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick);

    function unlock(bytes calldata data) external returns (bytes memory);

    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes calldata hookData)
        external
        returns (int256 callerDelta, int256 feesAccrued);

    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external
        returns (int256 swapDelta);

    /// @dev Native ETH settles with value; ERC20 settles after sync + transfer.
    function settle() external payable returns (uint256);

    function sync(address currency) external;

    function take(address currency, address to, uint256 amount) external;

    /// @dev Raw storage read (EIP-2330); backbone of all pool-state views here.
    function extsload(bytes32 slot) external view returns (bytes32);
}

/**
 * @title DiggerV4 (library)
 * @notice Stateless helpers: pool state reading via extsload, V4 tick/price math,
 *         liquidity-amount conversions, pending-fee accounting, and a single-step
 *         exact-input quoter that reproduces PoolManager swap math bit-for-bit.
 */
library DiggerV4 {
    // ------------------------------------------------------------------ types

    /// @dev Unpacked V4 Slot0 for one pool.
    struct Slot0 {
        // Q64.96 sqrt price; zero means the pool was never initialized
        uint160 sqrtPriceX96;
        // Tick matching sqrtPriceX96
        int24 tick;
        // Packed protocol fee setting
        uint24 protocolFee;
        // LP fee in millionths
        uint24 lpFee;
    }


    /// @dev Outcome of a swap unlock round-trip.
    struct SwapOutcome {
        uint256 amountIn;
        uint256 amountOut;
    }

    // -------------------------------------------------------------- constants

    /// @dev Absolute tick bound from V4 TickMath (pre spacing alignment).
    int24 internal constant MAX_TICK_BOUND = 887272;
    /// @dev sqrt price at tick -887272 (inclusive lower bound).
    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    /// @dev sqrt price at tick 887272 (EXCLUSIVE upper bound — initialize rejects ==).
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;
    /// @dev 2^96, the Q64.96 fixed-point unit.
    uint256 internal constant Q96 = 0x1000000000000000000000000;
    /// @dev 2^128, denominator of V4 fee-growth accumulators.
    uint256 internal constant Q128 = 0x100000000000000000000000000000000;
    /// @dev PoolKey.fee unit: millionths (10000 = 1%).
    uint256 internal constant FEE_DENOMINATOR = 1_000_000;

    /// @dev PoolManager storage: index of the pools mapping (StateLibrary.POOLS_SLOT).
    bytes32 internal constant POOLS_SLOT = bytes32(uint256(6));
    /// @dev Pool.State slot offsets (V4 storage layout).
    uint256 private constant OFFSET_FEE_GROWTH_GLOBAL0 = 1;
    uint256 private constant OFFSET_LIQUIDITY = 3;
    uint256 private constant OFFSET_TICKS = 4;
    uint256 private constant OFFSET_POSITIONS = 6;

    // ----------------------------------------------------------------- errors

    /// @notice A pool key needs a non-zero token address.
    error TokenRequired();
    /// @notice Tick spacing must be strictly positive.
    error SpacingInvalid();
    /// @notice Tick magnitude exceeds the V4 TickMath bound.
    error TickOutOfBounds();
    /// @notice A computed sqrt price no longer fits uint160.
    error SqrtPriceOverflow();
    /// @notice Downcast to uint128 would truncate.
    error CastOverflow();

    // ------------------------------------------------------- pool key helpers

    /**
     * @notice Builds the hookless ETH/TOKEN pool key and its poolId.
     * @dev ETH is pinned as currency0 and hooks are pinned to zero — Diggers never
     *      deviates. poolId matches V4 PoolIdLibrary (keccak of the abi-encoded key).
     * @param token The launched ERC20 (currency1); must be non-zero.
     * @param fee LP fee in millionths (Diggers uses 10000 = 1%).
     * @param tickSpacing Tick granularity (Diggers uses 200).
     * @return key The pool key.
     * @return poolId keccak256(abi.encode(key)).
     */
    function createPoolKey(address token, uint24 fee, int24 tickSpacing)
        internal
        pure
        returns (IPoolManagerLite.PoolKey memory key, bytes32 poolId)
    {
        if (token == address(0)) revert TokenRequired();
        key = IPoolManagerLite.PoolKey({
            currency0: address(0),
            currency1: token,
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: address(0)
        });
        poolId = keccak256(abi.encode(key));
    }

    /**
     * @notice Derives the position salt for an owner address.
     * @dev The Diggers launchpad is the only LP, so in practice this is always called
     *      with the launchpad's own address; the salt isolates its position per pool.
     * @param owner Position owner.
     * @return salt The address widened to bytes32.
     */
    function positionSalt(address owner) internal pure returns (bytes32 salt) {
        salt = bytes32(uint256(uint160(owner)));
    }

    /**
     * @notice Widest spacing-aligned tick bounds for a pool.
     * @dev V4 rejects position ticks that are not spacing multiples, so the usable
     *      full range is ±floor(887272 / spacing) · spacing (e.g. ±887200 at 200).
     * @param tickSpacing The pool's tick spacing; must be > 0.
     * @return tickLower Aligned minimum tick.
     * @return tickUpper Aligned maximum tick.
     */
    function fullRangeTicks(int24 tickSpacing) internal pure returns (int24 tickLower, int24 tickUpper) {
        if (tickSpacing <= 0) revert SpacingInvalid();
        int24 aligned = (MAX_TICK_BOUND / tickSpacing) * tickSpacing;
        return (-aligned, aligned);
    }

    // ------------------------------------------------------------- state reads

    /**
     * @notice Reads and unpacks a pool's Slot0 straight from PoolManager storage.
     * @dev Single extsload of pools[poolId] base slot; field layout is
     *      sqrtPriceX96 (160) | tick (24, signed) | protocolFee (24) | lpFee (24).
     * @param poolManager The V4 PoolManager.
     * @param poolId Pool identifier.
     * @return slot0 Decoded Slot0.
     */
    function getSlot0(address poolManager, bytes32 poolId) internal view returns (Slot0 memory slot0) {
        bytes32 stateSlot = keccak256(abi.encodePacked(poolId, POOLS_SLOT));
        bytes32 raw = IPoolManagerLite(poolManager).extsload(stateSlot);
        assembly {
            mstore(slot0, and(raw, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF))
            mstore(add(slot0, 0x20), signextend(2, shr(160, raw)))
            mstore(add(slot0, 0x40), and(shr(184, raw), 0xFFFFFF))
            mstore(add(slot0, 0x60), and(shr(208, raw), 0xFFFFFF))
        }
    }

    /**
     * @notice Whether a pool has been initialized.
     * @dev sqrtPriceX96 is set exactly once, by initialize; zero means never.
     */
    function isPoolInitialized(address poolManager, bytes32 poolId) internal view returns (bool) {
        return getSlot0(poolManager, poolId).sqrtPriceX96 != 0;
    }

    /**
     * @notice Reads a pool's currently active liquidity.
     * @dev Pool.State stores liquidity at base + 3.
     */
    function getPoolLiquidity(address poolManager, bytes32 poolId) internal view returns (uint128 liquidity) {
        bytes32 stateSlot = keccak256(abi.encodePacked(poolId, POOLS_SLOT));
        bytes32 raw = IPoolManagerLite(poolManager).extsload(bytes32(uint256(stateSlot) + OFFSET_LIQUIDITY));
        liquidity = uint128(uint256(raw));
    }

    /**
     * @notice Reads the two global fee-growth accumulators of a pool.
     */
    function getFeeGrowthGlobals(address poolManager, bytes32 poolId)
        internal
        view
        returns (uint256 feeGrowthGlobal0, uint256 feeGrowthGlobal1)
    {
        bytes32 stateSlot = keccak256(abi.encodePacked(poolId, POOLS_SLOT));
        bytes32 feeSlot = bytes32(uint256(stateSlot) + OFFSET_FEE_GROWTH_GLOBAL0);
        feeGrowthGlobal0 = uint256(IPoolManagerLite(poolManager).extsload(feeSlot));
        feeGrowthGlobal1 = uint256(IPoolManagerLite(poolManager).extsload(bytes32(uint256(feeSlot) + 1)));
    }

    /**
     * @notice Reads a tick's feeGrowthOutside pair.
     * @dev TickInfo layout: slot 0 packs liquidityGross|liquidityNet, slots 1 and 2
     *      hold the two outside accumulators.
     */
    function getTickFeeGrowthOutside(address poolManager, bytes32 poolId, int24 tick)
        internal
        view
        returns (uint256 feeGrowthOutside0, uint256 feeGrowthOutside1)
    {
        bytes32 stateSlot = keccak256(abi.encodePacked(poolId, POOLS_SLOT));
        bytes32 ticksSlot = bytes32(uint256(stateSlot) + OFFSET_TICKS);
        bytes32 tickSlot = keccak256(abi.encodePacked(int256(tick), ticksSlot));
        feeGrowthOutside0 = uint256(IPoolManagerLite(poolManager).extsload(bytes32(uint256(tickSlot) + 1)));
        feeGrowthOutside1 = uint256(IPoolManagerLite(poolManager).extsload(bytes32(uint256(tickSlot) + 2)));
    }

    /**
     * @notice Fee growth inside a tick range, following the V4 StateLibrary rules.
     * @dev feeGrowthOutside flips meaning depending on which side of the boundary the
     *      current tick sits, so both boundaries are conditionally mirrored through
     *      the global accumulator. The final subtraction wraps intentionally — V4 fee
     *      accounting is modular by specification.
     */
    function getFeeGrowthInside(address poolManager, bytes32 poolId, int24 tickLower, int24 tickUpper)
        internal
        view
        returns (uint256 feeGrowthInside0, uint256 feeGrowthInside1)
    {
        Slot0 memory slot0 = getSlot0(poolManager, poolId);
        (uint256 global0, uint256 global1) = getFeeGrowthGlobals(poolManager, poolId);
        (uint256 lowerOut0, uint256 lowerOut1) = getTickFeeGrowthOutside(poolManager, poolId, tickLower);
        (uint256 upperOut0, uint256 upperOut1) = getTickFeeGrowthOutside(poolManager, poolId, tickUpper);

        uint256 below0;
        uint256 below1;
        if (slot0.tick >= tickLower) {
            below0 = lowerOut0;
            below1 = lowerOut1;
        } else {
            below0 = global0 - lowerOut0;
            below1 = global1 - lowerOut1;
        }

        uint256 above0;
        uint256 above1;
        if (slot0.tick < tickUpper) {
            above0 = upperOut0;
            above1 = upperOut1;
        } else {
            above0 = global0 - upperOut0;
            above1 = global1 - upperOut1;
        }

        unchecked {
            feeGrowthInside0 = global0 - below0 - above0;
            feeGrowthInside1 = global1 - below1 - above1;
        }
    }

    /**
     * @notice Reads a position's liquidity and last fee-growth snapshots.
     * @dev Position key derivation matches V4 Position.calculatePositionKey; the
     *      Position.State layout is liquidity, then the two last-inside snapshots.
     */
    function getPositionInfo(
        address poolManager,
        bytes32 poolId,
        address owner,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt
    ) internal view returns (uint128 liquidity, uint256 feeGrowthInside0Last, uint256 feeGrowthInside1Last) {
        bytes32 positionKey = keccak256(abi.encodePacked(owner, tickLower, tickUpper, salt));
        bytes32 stateSlot = keccak256(abi.encodePacked(poolId, POOLS_SLOT));
        bytes32 positionsSlot = bytes32(uint256(stateSlot) + OFFSET_POSITIONS);
        bytes32 posSlot = keccak256(abi.encodePacked(positionKey, positionsSlot));
        liquidity = uint128(uint256(IPoolManagerLite(poolManager).extsload(posSlot)));
        feeGrowthInside0Last = uint256(IPoolManagerLite(poolManager).extsload(bytes32(uint256(posSlot) + 1)));
        feeGrowthInside1Last = uint256(IPoolManagerLite(poolManager).extsload(bytes32(uint256(posSlot) + 2)));
    }

    /**
     * @notice Pending (uncollected) LP fees of a position, without touching state.
     * @dev fees = liquidity · (feeGrowthInside_now − feeGrowthInside_last) / 2^128,
     *      the same formula PoolManager applies on the next modifyLiquidity. Ticks
     *      must be the position's actual bounds — Diggers positions are custom-range,
     *      so there is deliberately no full-range fallback here.
     * @return pendingFees0 ETH fees awaiting collection (wei).
     * @return pendingFees1 Token fees awaiting collection.
     */
    function getPendingV4Fees(
        address poolManager,
        bytes32 poolId,
        address owner,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt
    ) internal view returns (uint256 pendingFees0, uint256 pendingFees1) {
        (uint128 liquidity, uint256 last0, uint256 last1) =
            getPositionInfo(poolManager, poolId, owner, tickLower, tickUpper, salt);
        if (liquidity == 0) return (0, 0);

        (uint256 inside0, uint256 inside1) = getFeeGrowthInside(poolManager, poolId, tickLower, tickUpper);

        unchecked {
            // Wrapping deltas, per V4's modular fee accounting.
            uint256 delta0 = inside0 - last0;
            uint256 delta1 = inside1 - last1;
            // Floor division matches PoolManager exactly.
            pendingFees0 = DiggerMath.md512(uint256(liquidity), delta0, Q128);
            pendingFees1 = DiggerMath.md512(uint256(liquidity), delta1, Q128);
        }
    }

    // -------------------------------------------------------------- tick math

    /**
     * @notice sqrt(1.0001^tick) in Q64.96 — the canonical V4 TickMath routine.
     * @dev Bit-by-bit multiplication with the standard precomputed constants;
     *      byte-identical to the Uniswap reference. Reverts outside ±887272.
     */
    function getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        unchecked {
            uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
            if (absTick > uint256(int256(MAX_TICK_BOUND))) revert TickOutOfBounds();

            uint256 ratio = absTick & 0x1 != 0
                ? 0xfffcb933bd6fad37aa2d162d1a594001
                : 0x100000000000000000000000000000000;
            if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
            if (absTick & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
            if (absTick & 0x8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
            if (absTick & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
            if (absTick & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
            if (absTick & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
            if (absTick & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
            if (absTick & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
            if (absTick & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
            if (absTick & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
            if (absTick & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
            if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
            if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
            if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
            if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
            if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
            if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
            if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
            if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;

            if (tick > 0) ratio = type(uint256).max / ratio;

            // Q128.128 → Q64.96, rounding up on any truncated bits.
            sqrtPriceX96 = uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
        }
    }

    // ------------------------------------------------------------- price math

    /**
     * @notice Token-per-ETH spot price implied by a sqrt price, scaled 1e18.
     * @dev price = sqrtPrice² / 2^192, computed as two chained 512-bit mul-divs.
     */
    function sqrtPriceToPrice(uint160 sqrtPriceX96) internal pure returns (uint256 priceTokenPerEth) {
        uint256 sqrtPrice = uint256(sqrtPriceX96);
        uint256 squared = DiggerMath.md512(sqrtPrice, sqrtPrice, Q96);
        priceTokenPerEth = DiggerMath.md512(squared, 1e18, Q96);
    }

    /**
     * @notice ETH-per-token spot price implied by a sqrt price, scaled 1e18.
     * @dev inverse = 2^192 · 1e18 / sqrtPrice², split into two divisions by sqrtPrice
     *      because squaring first would overflow for sqrtPriceX96 > 2^128. Returns 0
     *      for an uninitialized pool (sqrtPrice == 0) instead of reverting.
     */
    function sqrtPriceToInversePrice(uint160 sqrtPriceX96) internal pure returns (uint256 priceEthPerToken) {
        uint256 sqrtPrice = uint256(sqrtPriceX96);
        if (sqrtPrice == 0) return 0;
        uint256 half = DiggerMath.md512(Q96, 1e18, sqrtPrice);
        priceEthPerToken = DiggerMath.md512(Q96, half, sqrtPrice);
    }

    /**
     * @notice Encodes an initial sqrt price from a deposit ratio (bootstrap helper).
     * @dev price = amount1/amount0 in raw units; result = sqrt(ratio·2^96)·2^48,
     *      clamped into [MIN_SQRT_RATIO, MAX_SQRT_RATIO) — the upper bound is
     *      exclusive because initialize rejects == MAX. Both amounts must be nonzero
     *      (amount0 == 0 reverts inside md512).
     */
    function encodePriceSqrt(uint256 amount0, uint256 amount1) internal pure returns (uint160 sqrtPriceX96) {
        uint256 ratioX96 = DiggerMath.md512(amount1, Q96, amount0);
        uint256 encoded = _isqrt(ratioX96) << 48;
        if (encoded < MIN_SQRT_RATIO) encoded = MIN_SQRT_RATIO;
        else if (encoded >= MAX_SQRT_RATIO) encoded = MAX_SQRT_RATIO - 1;
        sqrtPriceX96 = uint160(encoded);
    }

    /// @dev Babylonian floor square root.
    function _isqrt(uint256 x) private pure returns (uint256) {
        if (x == 0) return 0;
        uint256 estimate = (x + 1) / 2;
        uint256 best = x;
        while (estimate < best) {
            best = estimate;
            estimate = (x / estimate + estimate) / 2;
        }
        return best;
    }

    // -------------------------------------------------------- liquidity math

    /**
     * @notice Liquidity mintable from available amounts within explicit price bounds.
     * @dev Each currency implies its own liquidity figure; the smaller one binds
     *      (mirrors Uniswap LiquidityAmounts).
     */
    function getLiquidityForAmounts(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceLowerX96,
        uint160 sqrtPriceUpperX96,
        uint256 ethAmount,
        uint256 tokenAmount
    ) internal pure returns (uint128 liquidity) {
        uint128 fromEth = getLiquidityForAmount0(sqrtPriceX96, sqrtPriceUpperX96, ethAmount);
        uint128 fromToken = getLiquidityForAmount1(sqrtPriceLowerX96, sqrtPriceX96, tokenAmount);
        return fromEth < fromToken ? fromEth : fromToken;
    }

    /**
     * @notice Liquidity implied by a currency0 (ETH) amount over a price range.
     * @dev L = amount0 · sqrtA · sqrtB / Q96 / (sqrtB − sqrtA), 512-bit intermediates.
     */
    function getLiquidityForAmount0(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint256 amount0)
        internal
        pure
        returns (uint128)
    {
        if (sqrtPriceAX96 > sqrtPriceBX96) (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        uint256 intermediate = DiggerMath.md512(sqrtPriceAX96, sqrtPriceBX96, Q96);
        return toUint128(DiggerMath.md512(amount0, intermediate, sqrtPriceBX96 - sqrtPriceAX96));
    }

    /**
     * @notice Liquidity implied by a currency1 (token) amount over a price range.
     * @dev L = amount1 · Q96 / (sqrtB − sqrtA), 512-bit intermediates.
     */
    function getLiquidityForAmount1(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint256 amount1)
        internal
        pure
        returns (uint128)
    {
        if (sqrtPriceAX96 > sqrtPriceBX96) (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        return toUint128(DiggerMath.md512(amount1, Q96, sqrtPriceBX96 - sqrtPriceAX96));
    }

    /// @notice Like {getLiquidityForAmount1} but rounds liquidity up — used when
    ///         seeding the full fixed supply so no tokens strand on the launchpad.
    function getLiquidityForAmount1Up(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint256 amount1)
        internal
        pure
        returns (uint128)
    {
        if (sqrtPriceAX96 > sqrtPriceBX96) (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        return toUint128(DiggerMath.md512Up(amount1, Q96, sqrtPriceBX96 - sqrtPriceAX96));
    }

    /**
     * @notice ETH amount represented by a liquidity figure over a price range.
     * @dev amount0 = L · Q96 · (sqrtUpper − sqrtLower) / (sqrtLower · sqrtUpper),
     *      chained as two mul-divs to stay in 256 bits. Matches getAmount0Delta.
     */
    function getAmount0ForLiquidity(uint160 sqrtLowerX96, uint160 sqrtUpperX96, uint128 liquidity)
        internal
        pure
        returns (uint256)
    {
        if (sqrtLowerX96 > sqrtUpperX96) (sqrtLowerX96, sqrtUpperX96) = (sqrtUpperX96, sqrtLowerX96);
        return DiggerMath.md512(
            DiggerMath.md512(uint256(liquidity), Q96, uint256(sqrtUpperX96)),
            uint256(sqrtUpperX96) - uint256(sqrtLowerX96),
            uint256(sqrtLowerX96)
        );
    }

    /**
     * @notice Token amount represented by a liquidity figure over a price range.
     * @dev amount1 = L · (sqrtUpper − sqrtLower) / Q96. Matches getAmount1Delta.
     */
    function getAmount1ForLiquidity(uint160 sqrtLowerX96, uint160 sqrtUpperX96, uint128 liquidity)
        internal
        pure
        returns (uint256)
    {
        if (sqrtLowerX96 > sqrtUpperX96) (sqrtLowerX96, sqrtUpperX96) = (sqrtUpperX96, sqrtLowerX96);
        return DiggerMath.md512(uint256(liquidity), uint256(sqrtUpperX96) - uint256(sqrtLowerX96), Q96);
    }

    /**
     * @notice Both currency amounts held by a position at the current price.
     * @dev Below range → all ETH; above range → all tokens; in range → split at spot.
     *      A fresh Diggers launch sits exactly at the "above never, below at start"
     *      edge: spot == lower bound, so the whole supply is token-side.
     */
    function getAmountsForLiquidity(
        uint160 sqrtPriceX96,
        uint160 sqrtLowerX96,
        uint160 sqrtUpperX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (sqrtPriceX96 <= sqrtLowerX96) {
            amount0 = getAmount0ForLiquidity(sqrtLowerX96, sqrtUpperX96, liquidity);
        } else if (sqrtPriceX96 >= sqrtUpperX96) {
            amount1 = getAmount1ForLiquidity(sqrtLowerX96, sqrtUpperX96, liquidity);
        } else {
            amount0 = getAmount0ForLiquidity(sqrtPriceX96, sqrtUpperX96, liquidity);
            amount1 = getAmount1ForLiquidity(sqrtLowerX96, sqrtPriceX96, liquidity);
        }
    }

    /// @notice Checked uint256 → uint128 downcast.
    function toUint128(uint256 value) internal pure returns (uint128) {
        if (value > type(uint128).max) revert CastOverflow();
        return uint128(value);
    }

    // ----------------------------------------------------------- swap quoting
    //
    // The quoter reproduces the exact SqrtPriceMath/SwapMath sequence PoolManager
    // runs inside the current tick's active liquidity. For Diggers pools — a single
    // protocol position spanning [startTick, maxTick] — no swap can cross an
    // initialized tick without draining the pool, so the single-step quote is exact,
    // and minOut can be set within rounding-dust tolerance of the realized output.

    /**
     * @notice New sqrt price after adding amount0, rounded up (V4 exact behaviour).
     * @dev sqrtQ = (L·Q96·sqrtP) / (L·Q96 + amount0·sqrtP). The fast path multiplies
     *      directly when amount0·sqrtP fits 256 bits; the slow path rearranges to
     *      sqrtQ = L·Q96 / (L·Q96/sqrtP + amount0). Rounding up is conservative for
     *      input accounting, matching SqrtPriceMath.
     */
    function getNextSqrtPriceFromAmount0RoundingUp(uint160 sqrtPX96, uint128 liquidity, uint256 amount0)
        internal
        pure
        returns (uint160 sqrtQX96)
    {
        if (amount0 == 0) return sqrtPX96;
        uint256 numerator1 = uint256(liquidity) << 96;

        unchecked {
            uint256 product = amount0 * uint256(sqrtPX96);
            if (product / amount0 == uint256(sqrtPX96)) {
                uint256 denominator = numerator1 + product;
                if (denominator >= numerator1) {
                    uint256 next = DiggerMath.md512Up(numerator1, uint256(sqrtPX96), denominator);
                    if (next > type(uint160).max) revert SqrtPriceOverflow();
                    return uint160(next);
                }
            }
            uint256 altDenominator = (numerator1 / uint256(sqrtPX96)) + amount0;
            uint256 result = numerator1 / altDenominator;
            if (numerator1 % altDenominator != 0) result += 1;
            if (result > type(uint160).max) revert SqrtPriceOverflow();
            return uint160(result);
        }
    }

    /**
     * @notice New sqrt price after adding amount1, rounded down (V4 exact behaviour).
     * @dev sqrtQ = sqrtP + amount1·Q96/L, quotient floored. A single shift covers
     *      amount1 ≤ uint160 max; larger inputs take the 512-bit route.
     */
    function getNextSqrtPriceFromAmount1RoundingDown(uint160 sqrtPX96, uint128 liquidity, uint256 amount1)
        internal
        pure
        returns (uint160 sqrtQX96)
    {
        if (amount1 == 0) return sqrtPX96;

        uint256 quotient = (amount1 <= type(uint160).max)
            ? (amount1 << 96) / uint256(liquidity)
            : DiggerMath.md512(amount1, Q96, uint256(liquidity));

        uint256 result = uint256(sqrtPX96) + quotient;
        if (result > type(uint160).max) revert SqrtPriceOverflow();
        return uint160(result);
    }

    /**
     * @notice Read-only exact-input quote: the bit-exact output of the swap the pool
     *         would execute right now, single-step within active liquidity.
     * @dev Deducts the LP fee first (floored, missing wei stays as fee — same as V4),
     *      then walks the price. zeroForOne (ETH in) decreases the price and pays out
     *      L·ΔsqrtP/Q96; oneForZero (token in) increases it and pays out
     *      L·Q96·ΔsqrtP/(sqrtP_after·sqrtP_before), both floored per V4 output rules.
     *      Returns zeros for an uninitialized pool, empty liquidity, or zero input.
     * @param poolManager The V4 PoolManager.
     * @param key Pool key for the target pool.
     * @param zeroForOne Direction: true sells currency0 (ETH) for tokens.
     * @param amountIn Exact input, fee-inclusive.
     * @return amountOut Output the real swap would deliver.
     * @return sqrtPriceAfter Post-swap sqrt price (for impact display / tick checks).
     */
    function quoteExactInputSingle(
        address poolManager,
        IPoolManagerLite.PoolKey memory key,
        bool zeroForOne,
        uint256 amountIn
    ) internal view returns (uint256 amountOut, uint160 sqrtPriceAfter) {
        if (amountIn == 0) return (0, 0);

        bytes32 poolId = keccak256(abi.encode(key));
        Slot0 memory slot0 = getSlot0(poolManager, poolId);
        if (slot0.sqrtPriceX96 == 0) return (0, 0);

        uint128 liquidity = getPoolLiquidity(poolManager, poolId);
        if (liquidity == 0) return (0, 0);

        // Fee off the top, floored — identical to PoolManager's fee handling.
        uint256 amountInLessFee = DiggerMath.md512(amountIn, FEE_DENOMINATOR - uint256(key.fee), FEE_DENOMINATOR);

        if (zeroForOne) {
            sqrtPriceAfter = getNextSqrtPriceFromAmount0RoundingUp(slot0.sqrtPriceX96, liquidity, amountInLessFee);
            amountOut = DiggerMath.md512(
                uint256(liquidity), uint256(slot0.sqrtPriceX96) - uint256(sqrtPriceAfter), Q96
            );
        } else {
            sqrtPriceAfter = getNextSqrtPriceFromAmount1RoundingDown(slot0.sqrtPriceX96, liquidity, amountInLessFee);
            uint256 scaled = DiggerMath.md512(uint256(liquidity), Q96, uint256(sqrtPriceAfter));
            amountOut = DiggerMath.md512(
                scaled, uint256(sqrtPriceAfter) - uint256(slot0.sqrtPriceX96), uint256(slot0.sqrtPriceX96)
            );
        }
    }
}

/**
 * @title DiggerV4Base
 * @notice Abstract unlock-callback host. The inheriting contract (the Diggers
 *         launchpad) owns every V4 position and routes all pool interaction through
 *         three internal operations: add liquidity, collect fees, swap. There is no
 *         remove-liquidity operation — protocol liquidity is permanent.
 * @dev Settlement: native ETH pays with settle{value}; the token side syncs, then
 *      transfers via the abstract _transferToken hook, then settles. Output taking
 *      goes straight from the PoolManager to a recipient parked in EIP-1153
 *      transient storage for the duration of the unlock.
 */
abstract contract DiggerV4Base {
    /// @dev The V4 PoolManager; fixed for the contract's lifetime.
    address internal immutable POOL_MANAGER;

    /// @dev Unlock payload op codes.
    uint8 private constant OP_ADD = 1;
    uint8 private constant OP_COLLECT = 2;
    uint8 private constant OP_SWAP = 3;

    /// @notice Constructor received a zero PoolManager address.
    error PoolManagerRequired();
    /// @notice unlockCallback caller is not the PoolManager.
    error NotPoolManager();
    /// @notice Unlock payload carried an unknown op code.
    error UnknownOp();
    /// @notice Requested liquidity add computes to zero units.
    error ZeroLiquidityMint();
    /// @notice Swap input of zero.
    error ZeroSwapAmount();
    /// @notice Swap output fell below the caller's minimum.
    error Slippage();

    constructor(address poolManager) {
        if (poolManager == address(0)) revert PoolManagerRequired();
        POOL_MANAGER = poolManager;
    }

    // -------------------------------------------------- transient recipient

    /// @dev Transient slot for the current unlock's output recipient. Instance-scoped
    ///      domain string (differs from any prior deployment lineage).
    function _recipientSlot() private view returns (bytes32) {
        return keccak256(abi.encodePacked(address(this), "diggers.v4.recipient"));
    }

    function _stashRecipient(address recipient) private {
        bytes32 slot = _recipientSlot();
        assembly {
            tstore(slot, recipient)
        }
    }

    function _loadRecipient() private view returns (address recipient) {
        bytes32 slot = _recipientSlot();
        assembly {
            recipient := tload(slot)
        }
    }

    function _dropRecipient() private {
        bytes32 slot = _recipientSlot();
        assembly {
            tstore(slot, 0)
        }
    }

    // ------------------------------------------------------ external surface

    /**
     * @notice Entry point PoolManager calls back during unlock.
     * @dev Only the PoolManager may call. First word of the payload selects the
     *      operation; the rest is op-specific. Returns abi-encoded (int128, int128)
     *      balance deltas for the initiating internal function to decode.
     */
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != POOL_MANAGER) revert NotPoolManager();

        uint8 op = abi.decode(data[:32], (uint8));
        bytes memory params = data[32:];

        // OP_ADD and OP_COLLECT share a handler: a zero-liquidity "add" owes nothing
        // and only takes the auto-flushed fee deltas, which is exactly a collect.
        if (op == OP_ADD || op == OP_COLLECT) return _onAddLiquidity(params);
        if (op == OP_SWAP) return _onSwap(params);
        revert UnknownOp();
    }

    // ------------------------------------------------------------ operations

    /**
     * @notice Collects accrued LP fees from this contract's position, leaving the
     *         liquidity untouched.
     */
    function _collectFeesV4(
        IPoolManagerLite.PoolKey memory key,
        address owner,
        address recipient,
        int24 tickLower,
        int24 tickUpper
    ) internal returns (uint256 ethFees, uint256 tokenFees) {
        _stashRecipient(recipient);

        bytes memory payload =
            abi.encode(OP_COLLECT, key, int256(0), DiggerV4.positionSalt(owner), tickLower, tickUpper);
        bytes memory answer = IPoolManagerLite(POOL_MANAGER).unlock(payload);
        (int128 delta0, int128 delta1) = abi.decode(answer, (int128, int128));

        ethFees = delta0 > 0 ? uint256(uint128(delta0)) : 0;
        tokenFees = delta1 > 0 ? uint256(uint128(delta1)) : 0;

        _dropRecipient();
    }

    /**
     * @notice Executes an exact-input swap with an output floor.
     * @dev The in-pool price limit is pinned to the extreme end, so ALL slippage
     *      protection lives in `minAmountOut` — callers must always pass a real
     *      floor for value-bearing swaps. Output is taken directly from the
     *      PoolManager to `recipient` (this is what keeps buy/sell attribution
     *      clean in the token's transfer hooks).
     * @param key Pool key.
     * @param zeroForOne true = ETH in, tokens out; false = tokens in, ETH out.
     * @param amountIn Exact input, fee-inclusive.
     * @param recipient Output destination.
     * @param minAmountOut Revert floor for the output (0 disables — tests only).
     */
    function _swapV4(
        IPoolManagerLite.PoolKey memory key,
        bool zeroForOne,
        uint256 amountIn,
        address recipient,
        uint256 minAmountOut
    ) internal returns (DiggerV4.SwapOutcome memory result) {
        if (amountIn == 0) revert ZeroSwapAmount();

        _stashRecipient(recipient);

        bytes memory payload = abi.encode(OP_SWAP, key, zeroForOne, amountIn);
        bytes memory answer = IPoolManagerLite(POOL_MANAGER).unlock(payload);
        (int128 delta0, int128 delta1) = abi.decode(answer, (int128, int128));

        if (zeroForOne) {
            result.amountIn = delta0 < 0 ? uint256(uint128(-delta0)) : 0;
            result.amountOut = delta1 > 0 ? uint256(uint128(delta1)) : 0;
        } else {
            result.amountIn = delta1 < 0 ? uint256(uint128(-delta1)) : 0;
            result.amountOut = delta0 > 0 ? uint256(uint128(delta0)) : 0;
        }

        if (result.amountOut < minAmountOut) revert Slippage();

        _dropRecipient();
    }

    // -------------------------------------------------------------- handlers

    /// @dev ADD leg inside the unlock: mint the liquidity, pay what is owed, take any
    ///      auto-flushed fees to the stashed recipient.
    function _onAddLiquidity(bytes memory params) private returns (bytes memory) {
        (
            IPoolManagerLite.PoolKey memory key,
            int256 liquidityDelta,
            bytes32 salt,
            int24 tickLower,
            int24 tickUpper
        ) = abi.decode(params, (IPoolManagerLite.PoolKey, int256, bytes32, int24, int24));

        IPoolManagerLite.ModifyLiquidityParams memory modifyParams = IPoolManagerLite.ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: liquidityDelta,
            salt: salt
        });

        (int256 callerDelta,) = IPoolManagerLite(POOL_MANAGER).modifyLiquidity(key, modifyParams, "");
        (int128 delta0, int128 delta1) = _splitDelta(callerDelta);

        if (delta0 < 0) _settleV4(key.currency0, uint256(uint128(-delta0)));
        if (delta1 < 0) _settleV4(key.currency1, uint256(uint128(-delta1)));

        address recipient = _loadRecipient();
        if (recipient == address(0)) recipient = address(this);
        if (delta0 > 0) IPoolManagerLite(POOL_MANAGER).take(key.currency0, recipient, uint256(uint128(delta0)));
        if (delta1 > 0) IPoolManagerLite(POOL_MANAGER).take(key.currency1, recipient, uint256(uint128(delta1)));

        return abi.encode(delta0, delta1);
    }

    /// @dev SWAP leg inside the unlock: run the swap with the extreme price bound
    ///      (slippage enforced outside via minAmountOut), settle the input, take the
    ///      output to the stashed recipient.
    function _onSwap(bytes memory params) private returns (bytes memory) {
        (IPoolManagerLite.PoolKey memory key, bool zeroForOne, uint256 amountIn) =
            abi.decode(params, (IPoolManagerLite.PoolKey, bool, uint256));

        uint160 sqrtPriceLimit = zeroForOne ? DiggerV4.MIN_SQRT_RATIO + 1 : DiggerV4.MAX_SQRT_RATIO - 1;

        IPoolManagerLite.SwapParams memory swapParams = IPoolManagerLite.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: sqrtPriceLimit
        });

        int256 swapDelta = IPoolManagerLite(POOL_MANAGER).swap(key, swapParams, "");
        (int128 delta0, int128 delta1) = _splitDelta(swapDelta);

        address recipient = _loadRecipient();
        if (recipient == address(0)) recipient = address(this);

        if (delta0 < 0) _settleV4(key.currency0, uint256(uint128(-delta0)));
        if (delta1 < 0) _settleV4(key.currency1, uint256(uint128(-delta1)));

        if (delta0 > 0) IPoolManagerLite(POOL_MANAGER).take(key.currency0, recipient, uint256(uint128(delta0)));
        if (delta1 > 0) IPoolManagerLite(POOL_MANAGER).take(key.currency1, recipient, uint256(uint128(delta1)));

        return abi.encode(delta0, delta1);
    }

    // ---------------------------------------------------------------- helpers

    /// @dev Splits a packed BalanceDelta: currency0 in the upper 128 bits (arithmetic
    ///      shift preserves sign), currency1 sign-extended from the lower 128.
    function _splitDelta(int256 delta) private pure returns (int128 amount0, int128 amount1) {
        assembly {
            amount0 := sar(128, delta)
            amount1 := signextend(15, delta)
        }
    }

    /// @dev Pays a negative delta to the PoolManager. ETH rides on settle's value;
    ///      ERC20 follows the sync → transfer → settle sequence V4 requires.
    function _settleV4(address currency, uint256 amount) private {
        if (currency == address(0)) {
            IPoolManagerLite(POOL_MANAGER).settle{value: amount}();
        } else {
            IPoolManagerLite(POOL_MANAGER).sync(currency);
            _transferToken(currency, POOL_MANAGER, amount);
            IPoolManagerLite(POOL_MANAGER).settle();
        }
    }

    /// @notice Token transfer hook the inheriting contract must provide; used solely
    ///         to move tokens to the PoolManager during settlement.
    function _transferToken(address token, address to, uint256 amount) internal virtual;
}
