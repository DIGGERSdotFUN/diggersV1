// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {DiggerV4, IPoolManagerLite} from "./DiggerV4.sol";
import {DiggerLaunchLiquidity} from "./DiggerLaunchLiquidity.sol";
import {DiggersToken} from "../DiggersToken.sol";
import {IDiggers} from "../interfaces/IDiggers.sol";

/**
 * @title DiggerCreateLib
 * @notice Launch orchestration executed via `delegatecall` from `Diggers`. Tokens are
 *         deployed as 45-byte EIP-1167 minimal proxies onto the launchpad's single
 *         DiggersToken implementation and armed with `initialize` in the same frame —
 *         a launch pays a tiny CREATE2 instead of the full ~11 KB runtime deposit.
 * @dev Runs in Diggers' context: `address(this)` is the launchpad, so every CREATE2
 *      address, storage write, and transient recipient slot resolve exactly as if
 *      `create` ran inline (and `initialize`'s launchpad gate sees the right caller).
 *      The seed round-trip calls `unlock` directly; the callback returns to Diggers'
 *      `unlockCallback` (a fresh non-delegate call) which owns the OP_ADD handler.
 * @author BasedDopamine
 */
library DiggerCreateLib {
    uint256 private constant WAD = 1e18;
    uint256 private constant TOKEN_SUPPLY = 1_000_000_000e18;
    int24 private constant POOL_TICK_SPACING = 200;
    uint8 private constant OP_ADD = 1;

    /// @dev LP fee bounds, 1e18-scaled: 1% and 5%. Percentages are ALWAYS 1e18 here.
    uint256 private constant MIN_LP_FEE_WAD = 1e16;
    uint256 private constant MAX_LP_FEE_WAD = 5e16;

    /// @dev LP fee granularity: exactly a whole percent. Allowed set is {1,2,3,4,5}e16 —
    ///      fractional fees (e.g. 1.5%) are rejected.
    uint256 private constant LP_FEE_STEP_WAD = 1e16;

    /// @dev Divisor mapping a 1e18-scaled fee to V4 millionths: 1e18 wad → 1e6 ppm.
    uint256 private constant FEE_WAD_PER_MILLIONTH = 1e12;

    /// @dev Hard cap on creator fee-split rows (keeps harvest bounded).
    uint256 private constant MAX_FEE_SPLITS = 10;

    /**
     * @notice Deploys a token, initializes its pool, seeds the full supply, records the
     *         per-token fee config, and writes the initial creator fee-split table
     *         (later replaceable by the fee owner via {updateFeeSplits}).
     * @dev The atomic initial buy + distribution runs in `Diggers` after this returns
     *      (it reuses the internal swap router), so this library owns only deploy/seed/
     *      config. Percentages (`lpFeeWad`, `burnShareWad`, fee-split shares) are ALWAYS
     *      1e18-scaled.
     * @param isDiggersToken Registry-of-tokens flag map (storage pointer).
     * @param tokenRecords Per-token pool record map (storage pointer).
     * @param feeSplitCount Per-token fee-split row count map (storage pointer).
     * @param feeSplits Per-token fee-split table map (storage pointer).
     * @param poolManager Canonical V4 PoolManager.
     * @param startTick Spacing-aligned launch tick.
     * @param nonce Current CREATE2 salt nonce (caller increments its own copy).
     * @param params Identity + LP fee + burn-share config for the launch.
     * @param feeSplitsIn Creator ETH fee-share table (empty ⇒ default `[{creator, 1e18}]`).
     * @param tokenImplementation The shared DiggersToken implementation to clone.
     * @return token Address of the new DiggersToken clone.
     */
    function create(
        mapping(address => bool) storage isDiggersToken,
        mapping(address => IDiggers.TokenRecord) storage tokenRecords,
        mapping(address => uint8) storage feeSplitCount,
        mapping(address => mapping(uint256 => IDiggers.FeeSplit)) storage feeSplits,
        address poolManager,
        int24 startTick,
        uint256 nonce,
        IDiggers.TokenParams calldata params,
        IDiggers.FeeSplit[] memory feeSplitsIn,
        address tokenImplementation
    ) external returns (address token) {
        token = _deploy(isDiggersToken, _validate(params), params, nonce, tokenImplementation);
        _writeFeeSplits(feeSplitCount, feeSplits, token, feeSplitsIn);
        // Seed, write the record, and emit `Created` inside one helper so create()'s frame
        // stays shallow (this path is stack-sensitive under viaIR).
        _seedAndEmit(tokenRecords, poolManager, startTick, token, params);
    }

    /// @dev Seeds the pool + writes the record, then emits `Created` with the per-token
    ///      config (identity, deterministic poolId, creator-chosen fee + burn share).
    ///      Protocol-constant values (start price, seeded liquidity, position bounds) are
    ///      intentionally NOT in the event — an indexer reads them once from the launchpad.
    function _seedAndEmit(
        mapping(address => IDiggers.TokenRecord) storage tokenRecords,
        address poolManager,
        int24 startTick,
        address token,
        IDiggers.TokenParams calldata params
    ) private {
        uint24 poolFee = uint24(params.lpFeeWad / FEE_WAD_PER_MILLIONTH);
        _initSeedRecord(tokenRecords, poolManager, startTick, token, poolFee, params.burnShareWad);
        emit IDiggers.Created(
            token,
            msg.sender,
            params.name,
            params.symbol,
            params.metadataURI,
            tokenRecords[token].poolId,
            DiggerV4.getSqrtRatioAtTick(startTick),
            poolFee,
            uint128(params.burnShareWad)
        );
    }

    /// @dev Non-empty identity strings + fee config in range. Returns the V4 millionths
    ///      pool fee derived from the 1e18-scaled `lpFeeWad` (10000..50000 for 1%..5%).
    function _validate(IDiggers.TokenParams calldata params) private pure returns (uint24 poolFee) {
        if (bytes(params.name).length == 0) revert IDiggers.NameRequired();
        if (bytes(params.symbol).length == 0) revert IDiggers.SymbolRequired();
        if (bytes(params.metadataURI).length == 0) revert IDiggers.MetadataRequired();
        if (
            params.lpFeeWad < MIN_LP_FEE_WAD || params.lpFeeWad > MAX_LP_FEE_WAD
                || params.lpFeeWad % LP_FEE_STEP_WAD != 0
        ) {
            revert IDiggers.LpFeeOutOfRange();
        }
        if (params.burnShareWad > WAD) revert IDiggers.BurnShareInvalid();
        poolFee = uint24(params.lpFeeWad / FEE_WAD_PER_MILLIONTH);
    }

    /// @dev CREATE2-deploys an EIP-1167 minimal proxy of the shared implementation
    ///      (creator, symbol, nonce salt), arms it with `initialize` in the same frame,
    ///      and registers it. The clone is 45 bytes of forwarder code — deploying one
    ///      costs a fixed ~41k gas instead of the implementation's ~2.2M code deposit.
    function _deploy(
        mapping(address => bool) storage isDiggersToken,
        uint24 poolFee,
        IDiggers.TokenParams calldata params,
        uint256 nonce,
        address tokenImplementation
    ) private returns (address token) {
        bytes32 salt = keccak256(abi.encode(msg.sender, params.symbol, nonce));

        // Canonical EIP-1167: 10-byte creation code, then the 45-byte forwarder runtime
        // with the implementation address spliced in. Deployed via CREATE2.
        bytes memory initcode = abi.encodePacked(
            hex"3d602d80600a3d3981f3363d3d373d3d3d363d73",
            tokenImplementation,
            hex"5af43d82803e903d91602b57fd5bf3"
        );
        assembly ("memory-safe") {
            token := create2(0, add(initcode, 0x20), mload(initcode), salt)
        }
        if (token == address(0)) revert IDiggers.CloneFailed();

        DiggersToken(token).initialize(params.name, params.symbol, params.metadataURI, poolFee);
        isDiggersToken[token] = true;
    }

    /// @dev Initialize the pool, seed the full supply single-sided, and store the record.
    ///      The single position sits ENTIRELY below spot: [floorTick, startTick]. With ETH
    ///      as currency0, a range below spot is 100% token (currency1) / 0 ETH — the whole
    ///      supply becomes the ask-side curve. Buys (ETH→token, zeroForOne) push price down
    ///      into the range, releasing token and making it dearer in ETH.
    function _initSeedRecord(
        mapping(address => IDiggers.TokenRecord) storage tokenRecords,
        address poolManager,
        int24 startTick,
        address token,
        uint24 poolFee,
        uint256 burnShareWad
    ) private returns (bytes32 poolId) {
        IPoolManagerLite.PoolKey memory key;
        (key, poolId) = DiggerV4.createPoolKey(token, poolFee, POOL_TICK_SPACING);

        if (DiggerV4.isPoolInitialized(poolManager, poolId)) revert IDiggers.PoolAlreadyInitialized();
        IPoolManagerLite(poolManager).initialize(key, DiggerV4.getSqrtRatioAtTick(startTick));

        (int24 floorTick,) = DiggerV4.fullRangeTicks(POOL_TICK_SPACING);
        (uint256 tokenUsed, uint256 ethUsed) = _seed(poolManager, key, floorTick, startTick);

        // Sweep uint128-liquidity rounding dust so the launchpad holds zero supply.
        uint256 leftover = DiggersToken(token).balanceOf(address(this));
        if (leftover > 0) DiggersToken(token).transfer(poolManager, leftover);

        if (tokenUsed > TOKEN_SUPPLY) revert IDiggers.SeedIncomplete(TOKEN_SUPPLY, tokenUsed);
        if (DiggersToken(token).balanceOf(address(this)) != 0) {
            revert IDiggers.SeedIncomplete(0, DiggersToken(token).balanceOf(address(this)));
        }
        if (ethUsed != 0) revert IDiggers.SeedIncomplete(0, ethUsed);

        tokenRecords[token] = IDiggers.TokenRecord({
            creator: msg.sender,
            poolId: poolId,
            tickLower: floorTick,
            tickUpper: startTick,
            poolFee: poolFee,
            burnShareWad: uint128(burnShareWad)
        });
    }

    /// @dev Validates and stores the creator fee-split table at create. Empty input
    ///      defaults to the whole 70% creator slice going to the creator. Otherwise the
    ///      table is ≤10 rows, every recipient non-zero, and shares sum to exactly 1e18.
    function _writeFeeSplits(
        mapping(address => uint8) storage feeSplitCount,
        mapping(address => mapping(uint256 => IDiggers.FeeSplit)) storage feeSplits,
        address token,
        IDiggers.FeeSplit[] memory feeSplitsIn
    ) private returns (uint8 count) {
        uint256 n = feeSplitsIn.length;
        if (n == 0) {
            feeSplitCount[token] = 1;
            feeSplits[token][0] = IDiggers.FeeSplit({to: msg.sender, share: WAD});

            address[] memory defRecipients = new address[](1);
            uint256[] memory defShares = new uint256[](1);
            defRecipients[0] = msg.sender;
            defShares[0] = WAD;
            emit IDiggers.FeeSplitConfigured(token, defRecipients, defShares);
            return 1;
        }
        (address[] memory recipients, uint256[] memory shares) = _storeRows(feeSplitCount, feeSplits, token, feeSplitsIn);
        emit IDiggers.FeeSplitConfigured(token, recipients, shares);
        return uint8(n);
    }

    /// @notice Replaces a token's creator fee-split table post-launch (auth checked by the
    ///         caller — `Diggers.setFeeSplits`, fee-owner only). Runs via `delegatecall`,
    ///         so it writes the launchpad's own `_feeSplits`/`_feeSplitCount`.
    /// @dev Same validation as create's non-empty path: 1..10 rows, non-zero recipients,
    ///      shares summing to exactly 1e18. Empty input reverts (use create's default only
    ///      at launch). Stale rows beyond the new count become unreachable (reads are
    ///      bounded by `feeSplitCount`). Emits {FeeSplitUpdated}.
    /// @param feeSplitCount Per-token fee-split row count map (storage pointer).
    /// @param feeSplits Per-token fee-split table map (storage pointer).
    /// @param token The launched token whose table is being replaced.
    /// @param rowsIn The new fee-split rows.
    function updateFeeSplits(
        mapping(address => uint8) storage feeSplitCount,
        mapping(address => mapping(uint256 => IDiggers.FeeSplit)) storage feeSplits,
        address token,
        IDiggers.FeeSplit[] calldata rowsIn
    ) external {
        if (rowsIn.length == 0) revert IDiggers.FeeSplitInvalid();
        IDiggers.FeeSplit[] memory rows = rowsIn;
        (address[] memory recipients, uint256[] memory shares) = _storeRows(feeSplitCount, feeSplits, token, rows);
        emit IDiggers.FeeSplitUpdated(token, recipients, shares);
    }

    /// @dev Shared validate-and-store for a non-empty fee-split table: ≤10 rows, every
    ///      recipient non-zero, shares summing to exactly 1e18. Writes rows `[0..n)` and
    ///      sets the count; returns parallel arrays for the caller's event.
    function _storeRows(
        mapping(address => uint8) storage feeSplitCount,
        mapping(address => mapping(uint256 => IDiggers.FeeSplit)) storage feeSplits,
        address token,
        IDiggers.FeeSplit[] memory rows
    ) private returns (address[] memory recipients, uint256[] memory shares) {
        uint256 n = rows.length;
        if (n > MAX_FEE_SPLITS) revert IDiggers.FeeSplitInvalid();

        recipients = new address[](n);
        shares = new uint256[](n);
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            IDiggers.FeeSplit memory row = rows[i];
            if (row.to == address(0) || row.share == 0) revert IDiggers.FeeSplitInvalid();
            sum += row.share;
            feeSplits[token][i] = row;
            recipients[i] = row.to;
            shares[i] = row.share;
        }
        if (sum != WAD) revert IDiggers.FeeSplitInvalid();

        feeSplitCount[token] = uint8(n);
    }

    /// @dev Single-sided token seed over [tickLower, tickUpper] via a direct unlock. The
    ///      range is entirely below spot, so the deposit is 100% token1 / 0 ETH.
    function _seed(address poolManager, IPoolManagerLite.PoolKey memory key, int24 tickLower, int24 tickUpper)
        private
        returns (uint256 tokenUsed, uint256 ethUsed)
    {
        uint160 sqrtLower = DiggerV4.getSqrtRatioAtTick(tickLower);
        uint160 sqrtUpper = DiggerV4.getSqrtRatioAtTick(tickUpper);
        uint128 liquidity = DiggerLaunchLiquidity.maxLiquidityForAmount1(sqrtLower, sqrtUpper, TOKEN_SUPPLY);
        if (liquidity == 0) revert IDiggers.SeedIncomplete(TOKEN_SUPPLY, 0);

        bytes32 slot = keccak256(abi.encodePacked(address(this), "diggers.v4.recipient"));
        assembly {
            tstore(slot, address())
        }

        bytes memory payload =
            abi.encode(OP_ADD, key, int256(uint256(liquidity)), DiggerV4.positionSalt(address(this)), tickLower, tickUpper);
        bytes memory answer = IPoolManagerLite(poolManager).unlock(payload);
        (int128 delta0, int128 delta1) = abi.decode(answer, (int128, int128));

        assembly {
            tstore(slot, 0)
        }

        ethUsed = delta0 < 0 ? uint256(uint128(-delta0)) : 0;
        tokenUsed = delta1 < 0 ? uint256(uint128(-delta1)) : 0;
    }
}
