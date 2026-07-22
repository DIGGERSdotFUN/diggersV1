# On-Chain Examples & Event Reference

> Every transaction below is **real and live** on Robinhood Chain (chain 4663).
> Links go to the official Blockscout instance; append the same path to
> `https://robinscan.io` for the Robinscan explorer.

---

## Deployed contracts

| Contract | Address | Blockscout |
|---|---|---|
| **Diggers** (launchpad) | `0x4190a197e9c7c8D9ce1095c32e6666A13A996580` | [View](https://robinhoodchain.blockscout.com/address/0x4190a197e9c7c8D9ce1095c32e6666A13A996580) |
| **DiggersToken** (implementation) | `0xE15A52D171D655cFBA30D64C94821bE4cf623dD9` | [View](https://robinhoodchain.blockscout.com/address/0xE15A52D171D655cFBA30D64C94821bE4cf623dD9) |
| **DiggersCoin** ($DIG) | `0x4a64812C952C4684cB0C5169d57f3D0F95dC06e2` | [View](https://robinhoodchain.blockscout.com/address/0x4a64812C952C4684cB0C5169d57f3D0F95dC06e2) |
| **Uniswap V4 PoolManager** | `0x8366a39Cc670B4001A1121b8f6A443a643e40951` | [View](https://robinhoodchain.blockscout.com/address/0x8366a39Cc670B4001A1121b8f6A443a643e40951) |

---

## Function selectors

### Diggers.sol (launchpad)

| Selector | Function |
|---|---|
| `0xdb61c76e` | `buy(address token, uint256 minOut, address to)` |
| `0x2dc8f867` | `sell(address token, uint256 amountIn, uint256 minOut, address to)` |
| `0x67ce1287` | `create(TokenParams)` — simple launch |
| `0x404d93d6` | `create(TokenParams, FeeSplit[], LockOrder[], uint256)` — full launch with fee splits + locks |
| `0x0e5c011e` | `harvest(address token)` |
| `0x4e71d92d` | `claim()` |
| `0xff6d8d05` | `graduate(address token)` |
| `0xcab6a468` | `extendReservation(address token)` |
| `0xadcb4e25` | `buyAndLock(address token, uint256 minOut, LockOrder[])` |
| `0xe988c453` | `transferAndLock(address token, uint256 amount, LockOrder[])` |
| `0x0d7a94f6` | `quoteBuy(address token, uint256 ethIn)` — view |
| `0xd98b2f5c` | `quoteSell(address token, uint256 amountIn)` — view |
| `0x5166861a` | `setFeeSplits(address token, FeeSplit[])` |
| `0x883d0bb9` | `setBurnShare(address token, uint256 burnShareWad)` |
| `0xd2a569c3` | `startAirdrop()` |
| `0x9fc35b2e` | `setTeamShareWad(uint256)` |
| `0xe74b981b` | `setFeeRecipient(address)` |
| `0xf2fde38b` | `transferOwnership(address)` |
| `0x715018a6` | `renounceOwnership()` |

---

## Event topic0 reference

All events below are emitted by the **Diggers** contract (`0x4190…6580`) unless
noted otherwise. An indexer subscribes to this single address for the full
protocol feed, plus each token's ERC-20 Transfer/Approval at the token address.

| topic0 (first 10 bytes) | Event | Emitter |
|---|---|---|
| `0x1027ac1d…` | `Created` | Diggers |
| `0x7df5095d…` | `FeeSplitConfigured` | Diggers |
| `0x272b205f…` | `FeeSplitUpdated` | Diggers |
| `0xef94a0ad…` | `BurnShareUpdated` | Diggers |
| `0x136e332e…` | `FeeOwnershipTransferred` | Diggers |
| `0xee24d177…` | `BurnOwnershipTransferred` | Diggers |
| `0xed590b34…` | `FeeParked` | Diggers |
| `0x464ef255…` | `Swapped` | Diggers |
| `0x3ab3a223…` | `Harvested` | Diggers |
| `0xd8138f8a…` | `Claimed` | Diggers |
| `0x2e1d0cf0…` | `Contender` | Diggers |
| `0x46fc48cc…` | `ReservationExtended` | Diggers |
| `0x4a2dd56e…` | `Graduated` | Diggers |
| `0xe39ee6b8…` | `PoolTrade` | Diggers |
| `0xc31f84b3…` | `PointsCredited` | Diggers |
| `0xb267788b…` | `LeaderboardChanged` | Diggers |
| `0x38a5f924…` | `HolderCountChanged` | Diggers |
| `0xc8bdf32e…` | `EpochSettled` | Diggers |
| `0x95c3f77d…` | `AirdropPaid` | Diggers |
| `0x56b90294…` | `LockSet` | Diggers |
| `0x8be0079c…` | `OwnershipTransferred` | Diggers |
| `0x4c3b3305…` | `AirdropStarted` | Diggers |
| `0x7f308899…` | `TeamShareUpdated` | Diggers |
| `0x7a7b5a0a…` | `FeeRecipientUpdated` | Diggers |
| `0xddf252ad…` | `Transfer` (ERC-20) | Each token |
| `0x8c5be1e5…` | `Approval` (ERC-20) | Each token |
| `0xd2c5e200…` | `AirdropMinted` | DiggersCoin |
| `0x32046dc3…` | `Finalized` | DiggersCoin |

### Full event signatures (for topic0 computation)

```
Created(address,address,string,string,string,bytes32,uint160,uint24,uint128)
FeeSplitConfigured(address,address[],uint256[])
FeeSplitUpdated(address,address[],uint256[])
BurnShareUpdated(address,uint256)
FeeOwnershipTransferred(address,address,address)
BurnOwnershipTransferred(address,address,address)
FeeParked(address,address,uint256)
Swapped(address,address,bool,uint256,uint256,uint160,int24,uint128,uint256,uint256)
Harvested(address,address,uint256,uint256,uint256,uint256,uint256,uint256)
Claimed(address,uint256)
Contender(bytes32,bytes32,address,uint64)
ReservationExtended(bytes32,bytes32,address,address,uint256,uint64,uint64)
Graduated(address,bytes32,bytes32,uint32,uint256,uint256)
PoolTrade(address,address,bool,uint256,uint256,int24,uint32,uint256,uint256)
PointsCredited(address,uint256,address,bool,uint256,uint256,uint256)
LeaderboardChanged(address,uint256,address,address,uint256)
HolderCountChanged(address,address,bool,uint32)
EpochSettled(address,uint256,uint256,uint256,uint64)
AirdropPaid(address,uint256,address,uint256)
LockSet(address,address,uint128,uint64,uint64,uint32)
OwnershipTransferred(address,address)
AirdropStarted(uint64,uint64)
TeamShareUpdated(uint256)
FeeRecipientUpdated(address)
Transfer(address,address,uint256)
Approval(address,address,uint256)
AirdropMinted(address,address,uint256,uint256,uint256,uint256)
Finalized(uint256,uint256,uint256,uint256)
```

---

## Sample transactions

### 1. Token creation (`create`)

A single `create()` call deploys the token (EIP-1167 clone), mints 1B supply,
seeds V4 liquidity, and runs the initial buy — all in one transaction.

**Transaction:**
[`0xad7e03ccbddd0f4fe535f38b3216598599fffe69ea1a2741952515571ce2e097`](https://robinhoodchain.blockscout.com/tx/0xad7e03ccbddd0f4fe535f38b3216598599fffe69ea1a2741952515571ce2e097)

| Field | Value |
|---|---|
| From | `0x72529Bf45711fbe658085E36A5d3d3d0E0d62d97` |
| To | `0x4190a197e9c7c8D9ce1095c32e6666A13A996580` (Diggers) |
| Selector | `0xdb61c76e` (`buy` — the create wraps an internal buy) |
| Block | 12,332,177 |
| Gas used | 1,048,329 |
| Token deployed | `0xf5c1ea07a538ae8b0597dcac180efd6bffc13824` (TEST / MissingNo) |

**Events emitted (12 logs):**

| # | Event | Emitter | Description |
|---|---|---|---|
| 0 | `Transfer` | Token | Mint: 1B tokens → Diggers (initial supply) |
| 1 | `FeeSplitConfigured` | Diggers | Creator fee table set |
| 2 | PoolManager internal | PoolManager | Pool initialization + liquidity provision |
| 3 | PoolManager internal | PoolManager | Swap callback |
| 4 | `Transfer` | Token | Creation-fee burn |
| 5 | `Transfer` | Token | Initial buy output → creator |
| 6 | `Created` | Diggers | Full creation record (name, symbol, poolId, fee, burnShare) |
| 7 | `Contender` | Diggers | Name/symbol registry lock (1h) |
| 8 | PoolManager internal | PoolManager | Swap settle |
| 9 | `Transfer` | Token | Tokens to buyer |
| 10 | `Swapped` | Diggers | Post-trade state (price, tick, liquidity, reserves) |
| 11 | `Transfer` | Token | Dust settlement |

---

### 1b. Token creation with fee splits + vesting locks

The full `create()` overload with a custom fee-split table and vesting locks
on the initial buy output.

**Transaction:**
[`0x0b4c6067830c4b5b638d2d12a288943ee4f1b3e0a0b39e958f4c31dfff5b08ca`](https://robinhoodchain.blockscout.com/tx/0x0b4c6067830c4b5b638d2d12a288943ee4f1b3e0a0b39e958f4c31dfff5b08ca)

| Field | Value |
|---|---|
| Token deployed | `0x375648af4149eace7431741b6abbf3f61d0d6144` (PABLO) |
| Creator | `0x78f1ddd26d21eb532ad603c626a68af6526b160f` |

This transaction includes:
- `FeeSplitConfigured` — custom creator fee table
- `LockSet` — tranche vesting lock on initial buy output (4 tranches over 30 days)
- `Contender` — name/symbol registry entries
- All standard creation events (supply mint, pool init, initial buy)

---

### 2. Buy swap (direct through Diggers)

A standalone `buy()` call. The buyer sends ETH and receives tokens. No
approval needed — the launchpad routes through V4 directly.

**Transaction:**
[`0x8efc28aa8bf16de496b2d2b654ac221d08a3d2b3ce88030c148ac57647937577`](https://robinhoodchain.blockscout.com/tx/0x8efc28aa8bf16de496b2d2b654ac221d08a3d2b3ce88030c148ac57647937577)

| Field | Value |
|---|---|
| From | `0x72529Bf45711fbe658085E36A5d3d3d0E0d62d97` |
| To | `0x4190a197e9c7c8D9ce1095c32e6666A13A996580` (Diggers) |
| Selector | `0xdb61c76e` (`buy`) |
| Value | 0.0002 ETH |
| Block | 12,336,201 |
| Gas used | 426,621 |
| Token | `0xf5c1ea07a538ae8b0597dcac180efd6bffc13824` (TEST) |

**Events emitted (9 logs):**

| # | Event | Emitter | What it tells you |
|---|---|---|---|
| 0 | PoolManager internal | PoolManager | V4 swap execution |
| 1 | `HolderCountChanged` | Diggers | New holder added (if first buy) |
| 2 | `PointsCredited` | Diggers | Points earned: `isBuy=true`, score, lifetime |
| 3 | `LeaderboardChanged` | Diggers | Entered top-10 (or evicted someone) |
| 4 | `PoolTrade` | Diggers | Trade telemetry: ethValue, tick, holders, cumVolume, epoch |
| 5 | `Transfer` | $DIG | Airdrop mint (during airdrop window) |
| 6 | `AirdropMinted` | $DIG | Airdrop details: potEthWei, minted, cumMinted |
| 7 | `Transfer` | Token | Tokens delivered to buyer |
| 8 | `Swapped` | Diggers | Full post-trade snapshot: sqrtPrice, tick, liquidity, reserves |

**Key indexed fields in `Swapped`:**
```
topic1: token address (indexed)
topic2: trader address (indexed)
topic3: isBuy (indexed, true = buy)
data:   ethAmount | tokenAmount | sqrtPriceAfterX96 | tickAfter | liquidityAfter | ethInPool | tokenInPool
```

**Key indexed fields in `PoolTrade`:**
```
topic1: token address (indexed)
topic2: trader address (indexed)
topic3: isBuy (indexed, true = buy)
data:   tokenAmount | ethValue | tick | holdersAfter | volumeEthCumAfter | epoch
```

---

### 3. Sell swap (direct through Diggers)

A `sell()` call. The seller sends tokens and receives ETH. **No approval
needed** — the launchpad pulls tokens directly from msg.sender (the token's
`transferFrom` skips the allowance check when the caller is the launchpad).

**Transaction:**
[`0x1f8cd6619b7817c46788a1bad72cc84adc33a6bea0101c801b4b5d5fa1b10f4a`](https://robinhoodchain.blockscout.com/tx/0x1f8cd6619b7817c46788a1bad72cc84adc33a6bea0101c801b4b5d5fa1b10f4a)

| Field | Value |
|---|---|
| From | `0x72529Bf45711fbe658085E36A5d3d3d0E0d62d97` |
| To | `0x4190a197e9c7c8D9ce1095c32e6666A13A996580` (Diggers) |
| Selector | `0x2dc8f867` (`sell`) |
| Value | 0 (no ETH sent — seller receives ETH) |
| Block | 12,438,013 |
| Gas used | 255,014 |
| Token | `0x808cb7211ab225de0713e7b925433435194ed78a` |

**Events emitted (6 logs):**

| # | Event | Emitter | What it tells you |
|---|---|---|---|
| 0 | PoolManager internal | PoolManager | V4 swap execution |
| 1 | `HolderCountChanged` | Diggers | Holder removed (if balance zeroed) |
| 2 | `PointsCredited` | Diggers | Points earned: `isBuy=false`, lower multiplier |
| 3 | `PoolTrade` | Diggers | Trade telemetry |
| 4 | `Transfer` | Token | Tokens pulled from seller → PoolManager |
| 5 | `Swapped` | Diggers | Full post-trade snapshot |

---

### 4. Harvest (fee collection + split)

A `harvest()` call collects all accrued LP fees from the V4 pool and splits
them: ETH side → team + platform + creator table (pull credits); token side →
burn share burned, remainder → daily contest pot.

**Transaction (with both ETH and token fees):**
[`0xde3807bb7729c582c3455fc23421886beea0af7637a116694ae7ebfcc5192aab`](https://robinhoodchain.blockscout.com/tx/0xde3807bb7729c582c3455fc23421886beea0af7637a116694ae7ebfcc5192aab)

| Field | Value |
|---|---|
| Selector | `0x0e5c011e` (`harvest`) |
| Token | `0x31d6a5dacffeddc7175aa81b55a9d9814d7ad4be` (4 Fish) |
| ETH total | 495,499,999,999,999 wei (~0.000495 ETH) |
| Tokens burned | 310,036,359,501,590,781,294,972 |
| Tokens to pot | 34,448,484,389,065,642,366,108 |

**Another harvest with token burns (CAT token, July 22):**
[`0x49edd0177a9ccbea6d7078974b468c00daf6806061d93d545edcc08da009356a`](https://robinhoodchain.blockscout.com/tx/0x49edd0177a9ccbea6d7078974b468c00daf6806061d93d545edcc08da009356a)

**Events emitted in a harvest:**

| # | Event | Emitter | What it tells you |
|---|---|---|---|
| — | PoolManager internal | PoolManager | Fee collection from V4 position |
| — | `Transfer` (burn) | Token | Token-side fees burned (to address(0)) |
| — | `Transfer` (pot) | Token | Token-side remainder → token contract (daily pot) |
| — | `Harvested` | Diggers | Full split: ethTotal, ethToTeam, ethToPlatform, ethToCreators, tokensBurned, tokensToPot |
| — | `Transfer` | $DIG | $DIG airdrop mint (if during airdrop window) |
| — | `AirdropMinted` | $DIG | Airdrop details |
| — | `Swapped` | Diggers | Post-harvest pool state snapshot |

**Key fields in `Harvested`:**
```
topic1: token address (indexed)
topic2: caller address (indexed)
data:   ethTotal | ethToTeam | ethToPlatform | ethToCreators | tokensBurned | tokensToPot
```

---

### 5. Epoch settlement (daily contest payout)

Settlement is lazy — it piggybacks on the first transfer after the 24h epoch
deadline. The carrying transfer is NOT blocked; the settlement runs first,
then the transfer completes normally.

**Transaction:**
[`0xe120e79bb35ea4b74c6b4a9f923d88558b1de8fe5ee1b9796166882136c46ac5`](https://robinhoodchain.blockscout.com/tx/0xe120e79bb35ea4b74c6b4a9f923d88558b1de8fe5ee1b9796166882136c46ac5)

| Field | Value |
|---|---|
| Token | `0x758aa6bcf074b12043b53fe393cdaa28a2a918fa` |
| Epoch settled | 0 |
| Settlement block | 15,249,983 |

**Events emitted in a settlement:**

| # | Event | Emitter | What it tells you |
|---|---|---|---|
| — | `Transfer` × N | Token | Pot distributed to each winning leader |
| — | `AirdropPaid` × N | Diggers | One per winner: epoch, winner address, amount |
| — | `EpochSettled` | Diggers | potPerWinner, rolledOver (unclaimed), nextDeadline |
| — | (then the normal trade events follow for the carrying transfer) |

**Key fields in `EpochSettled`:**
```
topic1: token address (indexed)
topic2: epoch number (indexed)
data:   potPerWinner | rolledOver | nextDeadline
```

**Key fields in `AirdropPaid`:**
```
topic1: token address (indexed)
topic2: epoch number (indexed)
topic3: winner address (indexed)
data:   amount (tokens paid to this winner)
```

---

### 6. Canonical Uniswap V4 pool interaction

Every Diggers pool is a standard hookless Uniswap V4 pool. The pool key is:

```
currency0: address(0)              (native ETH)
currency1: token address           (the launched ERC-20)
fee:       dynamic (lpFee flag)    (set per-token at creation, 1–5%)
tickSpacing: 200
hooks:     address(0)              (no hooks)
```

**Pool initialization** happens inside the `create()` transaction. The pool is
initialized at `START_SQRT_PRICE_X96` (~pump.fun-like start price, ~1.33 ETH
FDV for 1 billion supply).

The Diggers contract is the **only LP** of every pool. It holds a single
full-range position from `startTick` to `MAX_TICK` (887200). There is no
function to remove this liquidity — it is locked forever by code.

External routers (Universal Router, aggregators) can swap through the same V4
pool via the PoolManager. The Diggers contract's `buy()` and `sell()` are the
recommended entry points because they handle fee attribution, points, and
telemetry automatically.

---

### 7. Airdrop start

The protocol owner calls `startAirdrop()` once, opening the 30-day $DIG
mining window. Every buy on any Diggers token then mints $DIG to the buyer.

**Transaction:**
[`0x6f45291fbec50360ce3fa87d357bc54092e928bca4bdc395880f474afa128571`](https://robinhoodchain.blockscout.com/tx/0x6f45291fbec50360ce3fa87d357bc54092e928bca4bdc395880f474afa128571)

| Field | Value |
|---|---|
| Selector | `0xd2a569c3` (`startAirdrop`) |
| Block | 12,296,565 |

**Event emitted:**

| Event | Emitter | Fields |
|---|---|---|
| `AirdropStarted` | Diggers | `start` (unix), `end` (unix = start + 30 days) |

---

## Answers for integration forms

These are pre-filled answers for common listing/integration questionnaires
(DexScreener, DexTools, terminal applications, etc.).

### Can quote token be changed?

**No.** Every pool is ETH (native) / token. The quote token is always ETH
(currency0 = address(0)). It cannot be changed after creation.

### How are fees charged?

The pool fee is set per-token at creation (1–5%, stored as V4 dynamic lpFee).
Fees accrue in the V4 pool's own fee accounting. They are collected via
`harvest(token)` and split:

- **ETH-side fees** → 30% team + 70% creator fee-split table (pull payments via `claim()`)
- **Token-side fees** → `burnShareWad` burned + remainder to daily contest pot

The fee percentage is immutable per pool. The split ratios can be adjusted by
the token's fee/burn owners (or frozen if they renounce).

### Program IDL

N/A (EVM / Solidity, not Solana).

### Program / Contract addresses

| Role | Address |
|---|---|
| **Factory + Router** | `0x4190a197e9c7c8D9ce1095c32e6666A13A996580` |
| **Token implementation** | `0xE15A52D171D655cFBA30D64C94821bE4cf623dD9` |
| **Platform coin ($DIG)** | `0x4a64812C952C4684cB0C5169d57f3D0F95dC06e2` |
| **V4 PoolManager** | `0x8366a39Cc670B4001A1121b8f6A443a643e40951` |

### Sample of buy swap

[`0x8efc28aa8bf16de496b2d2b654ac221d08a3d2b3ce88030c148ac57647937577`](https://robinhoodchain.blockscout.com/tx/0x8efc28aa8bf16de496b2d2b654ac221d08a3d2b3ce88030c148ac57647937577)

### Sample of sell swap

[`0x1f8cd6619b7817c46788a1bad72cc84adc33a6bea0101c801b4b5d5fa1b10f4a`](https://robinhoodchain.blockscout.com/tx/0x1f8cd6619b7817c46788a1bad72cc84adc33a6bea0101c801b4b5d5fa1b10f4a)

### Sample pool / bonding curve initialization event

There is **no bonding curve**. The pool is a standard Uniswap V4 pool
initialized inside the `create()` transaction:

[`0xad7e03ccbddd0f4fe535f38b3216598599fffe69ea1a2741952515571ce2e097`](https://robinhoodchain.blockscout.com/tx/0xad7e03ccbddd0f4fe535f38b3216598599fffe69ea1a2741952515571ce2e097)

The `Created` event in this transaction contains: token address, creator,
name, symbol, metadataURI, V4 poolId, startSqrtPriceX96, poolFee, burnShareWad.

### Sample graduation event

No token has graduated yet on the current deployment. Graduation requires:
500+ holders, 540+ ETH cumulative volume, and 270+ ETH mean-daily-tick mcap.
The `Graduated` event will be emitted by the Diggers contract when a token
first meets all three criteria.

**Event signature:**
```
Graduated(address indexed token, bytes32 indexed nameKey, bytes32 indexed symbolKey, uint32 holders, uint256 volumeEthCum, uint256 avgMcapEth)
```

---

## Explorer links

All transactions above can be viewed on either explorer:

- **Blockscout** (recommended, always available):
  `https://robinhoodchain.blockscout.com/tx/{hash}`

- **Robinscan** (Robinhood's own explorer):
  `https://robinscan.io/tx/{hash}`

Token pages:
- `https://robinhoodchain.blockscout.com/token/{address}`
- `https://robinscan.io/token/{address}`

Address pages:
- `https://robinhoodchain.blockscout.com/address/{address}`
- `https://robinscan.io/address/{address}`

---

## API endpoints

See [INTEGRATIONS.md](./INTEGRATIONS.md) for the full list of public REST
endpoints (token info, Uniswap token list, metadata).

| Endpoint | Description |
|---|---|
| `GET https://diggers.fun/api/token-info` | Paginated token list (DexScreener-shaped) |
| `GET https://diggers.fun/api/token-info/{address}` | Single token detail |
| `GET https://diggers.fun/tokenlist.json` | Uniswap token-list schema |
| `GET https://diggers.fun/llms.txt` | AI/LLM crawler summary |

All endpoints serve CORS `*` and `Cache-Control: public, s-maxage=60`.
