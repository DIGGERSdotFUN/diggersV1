<p align="center">
  <img src="https://diggers.fun/diggers-pickaxe.png" width="80" />
</p>

<h1 align="center">Diggers V1</h1>

<p align="center">
  <b>The last meme-coin launcher.</b><br/>
  One transaction. One billion tokens. Locked liquidity forever.<br/>
  No bonding curve. No migration. No admin keys. Just the mine.
</p>

<p align="center">
  <a href="https://diggers.fun">Website</a> ·
  <a href="https://diggers.fun/doc">Docs</a> ·
  <a href="https://x.com/diggersdotfun">𝕏</a> ·
  <a href="https://t.me/diggersdotfun">Telegram</a> ·
  <a href="./INTEGRATIONS.md">Integrations</a>
</p>

---

Diggers is a fair launchpad on [Robinhood Chain](https://docs.robinhood.com/chain)
(chain 4663), built natively on Uniswap V4. Every launch deploys a fixed
1,000,000,000 supply ERC-20, seeds its entire supply as permanent single-sided
liquidity in a hookless V4 pool, and starts trading in the same block — no
bonding curve, no migration step, no admin keys over balances or liquidity.
The core mechanics are immutable from the first block.

This repository contains the **complete Solidity sources** of the protocol.

| | |
|---|---|
| **Chain** | Robinhood Chain (4663) · Arbitrum Orbit L2 · native ETH |
| **Compiler** | `solc ^0.8.35` · `viaIR` · optimizer |
| **License** | Business Source License 1.1 → GPL-2.0-or-later |
| **ENS** | `diggersdotfun.eth` |
| **Deployments** | [`v1-deployments.diggersdotfun.eth`](https://robinhoodchain.blockscout.com/address/0x4190a197e9c7c8D9ce1095c32e6666A13A996580) |

## Protocol in one minute

```
Creator calls create()
  │
  ├─ 1. Deploy ──► EIP-1167 clone of DiggersToken (45 bytes)
  ├─ 2. Mint ────► 1,000,000,000 tokens → Launchpad
  ├─ 3. Seed ────► Full supply as single-sided liquidity in V4 pool
  ├─ 4. Buy ─────► Creation fee → pool buy → burn (gives the pool its first trade)
  │                Remaining ETH → initial buy → creator / lock recipients
  └─ 5. Live ───► Trading starts in the same block
```

- **No rug possible.** The Launchpad is the pool's only LP and has no withdrawal
  function. Supply has no mint. Sells need no approval. There is no pause, no
  proxy, no upgrade path.
- **Fees flow, not drain.** 1–5% pool fee → harvested → 30% team / 70% creator
  split table → pull payments. Token-side fees → part burned, part to the daily
  contest pot.
- **Trade to earn.** Every pool trade earns digging points (buys 4×, sells 1×).
  Top 10 of each 24h epoch split the daily pot. Settled lazily.
- **Graduate to lock your name.** 500 holders + 540 ETH volume + 270 ETH mean
  mcap → Blue Chip. Lock your name and ticker forever with paid reservations.
- **$DIG airdrop.** During a 30-day window, every buy on any Diggers token mines
  $DIG coins. Weekly halving. Then finalize: LP on V2 (burned), team mint,
  transfers unlock.

---

## How Diggers is different

Every EVM launchpad before Diggers follows the same playbook: deploy a token,
pair it with ETH on a bonding curve, wait for it to "graduate" to a real DEX
(Uniswap, Raydium), and hope the migration doesn't get sniped. Diggers throws
that entire model away.

| | Traditional launchpad (pump.fun, etc.) | Diggers |
|---|---|---|
| **Pool at launch** | Bonding curve (custom AMM). The real Uniswap pool only exists after graduation. Bots snipe the migration tx | Uniswap V4 pool from block one. No bonding curve, no migration, no snipe window |
| **Liquidity** | Removable by the deployer or migration contract. Rug vector | The Launchpad is the sole LP and has **no withdraw function**. Locked forever by code, not by promise |
| **Supply** | Often mintable, or hidden admin functions | Fixed 1B supply, non-mintable, burnable. `totalSupply` only goes down |
| **Sells** | Require an approve tx (or wallet signature). Users forget to revoke | Approve-free. The token trusts the Launchpad under two hard conditions (your tokens, inside the sell flow). Nothing to revoke |
| **Fee model** | Platform takes a cut; creator gets nothing, or a one-time payout | Creator picks their own pool fee (1–5%) and an immutable fee-split table (up to 10 recipients). Fees flow forever via pull payments |
| **Graduation** | "Market cap reaches X" → migrate to DEX. Often gamed, centrally decided | Already on Uniswap V4. "Graduation" means Blue Chip status: 500 holders + 540 ETH volume + 270 ETH mcap. No migration needed — the pool is the same pool |
| **Admin keys** | Pausable, upgradeable, owner can freeze/seize | No pause, no proxy, no upgrade path. One bounded `owner` for config only (fee wallet, airdrop start). Can be renounced forever |
| **Token code** | Usually a vanilla ERC-20, or a proxy with hidden logic | 7-layer `_update` pipeline: anti-whale cap, approve-free sells, points, leaderboard, lazy settlement, graduation telemetry, vesting locks — all in one immutable contract |

## What's new (never seen before on EVM)

### Digging points & the daily traders contest

Every pool trade on a Diggers token earns **digging points**. Buys are worth 4×
the same-size sell. A rolling top-10 leaderboard tracks the highest scorers of
each 24-hour epoch, and when the epoch ends, the top 10 split a daily airdrop
pot (funded by the token-side LP fees that aren't burned). Settlement is lazy —
it piggybacks on the first transfer after the deadline, so there is no keeper
bot and no gas cost to the protocol.

This is the first on-chain trade-to-earn contest that runs per-token, fully
in the ERC-20's own `_update` hook, with no external oracle, no off-chain
leaderboard, and no admin who picks winners.

### On-chain name registry (contenders & reservations)

Name and ticker are **case-insensitive registry keys** enforced byte-by-byte
on-chain (A–Z → a–z fold, only ASCII alphanumeric + single internal spaces for
names, alphanumeric only for symbols). Every launch locks both keys for 1 hour.
If the coin graduates in its first 24 hours, the first minter holds the name
free for that window. After that, anyone can pay to extend a graduated token's
reservation: **1 ETH = 365 days**, compounding, up to a 100-year cap. Proceeds
go to the team treasury via pull payments.

No other launchpad has an on-chain DNS-like system where names can be contested,
defended, and permanently secured by the community through economic skin in the
game.

### Approve-free sells

The token's `transferFrom` skips the allowance check entirely when the caller is
the Launchpad — and the Launchpad only ever pulls from `msg.sender` of the outer
call, inside the sell flow. No approve transaction. No infinite allowance sitting
in some contract. Nothing to revoke. One less transaction on every sell, and one
less attack surface forever.

### Buy-mining platform airdrop ($DIG)

During a one-time 30-day window, every buy on any Diggers token mines $DIG
platform coins to the buyer. The mint rate starts at 100,000 DIG per ETH of
platform fee and halves every 7 days. After the window, `finalize()` pairs 10%
of final supply with all accrued ETH on Uniswap V2 (LP burned permanently),
mints 50% to the team, and unlocks transfers. Final split: 40% airdrop / 10%
LP / 50% team — but the absolute numbers are entirely demand-driven. No
pre-mine, no seed round, no VC allocation.

### Creator fee-split tables

At launch, the creator sets an immutable fee-split table with up to 10 ETH
recipients (collaborators, artists, charities, DAOs) — each with a 1e18-scaled
share. The table can be edited post-launch by the fee owner (who can also
renounce, freezing it forever). Fees are pull payments, not push — no one can
brick the protocol by reverting a receive.

### Vesting locks (on-chain, in the ERC-20)

Create-time distribution can lock tokens with tranche vesting: N equal slices
over a duration, enforced in the token's own `_update`. Tokens stay in the
holder's wallet (visible on explorers), but movement is gated. One lock per
address, max 10 per token. No external vesting contract, no claim portal —
it's in the token itself.

## Graduation explained

On traditional launchpads, "graduation" means migrating liquidity from a bonding
curve to a real DEX. On Diggers, **the token is already on Uniswap V4 from block
one** — there is nothing to migrate.

Instead, graduation is a **Blue Chip status** that unlocks one privilege: the
ability to permanently reserve your token's name and ticker on the on-chain
registry. It is a badge of legitimacy, not a liquidity event.

### The three criteria (all measured on-chain, pool legs only)

| Criterion | Threshold | What it proves |
|---|---|---|
| **Holders** | ≥ 500 unique addresses | Real distribution, not a few whales |
| **Volume** | ≥ 540 ETH cumulative | Sustained trading activity |
| **Market cap** | ≥ 270 ETH mean-daily-tick mcap | The market values the token, not just trades it |

All three are pure ETH constants — no oracle, no committee, no vote. The token
contract itself tracks holders (pool buys add, zeroing removes), cumulative
volume (priced at pool spot each leg), and daily closing ticks (one per UTC day).
The graduation math computes the mean tick over the last 7 non-empty trading
days and derives the ETH market cap from it.

### How it works

1. A token meets all three criteria.
2. Anyone calls `graduate(token)` (or it auto-triggers on the next trade within
   the first 24 hours).
3. The contract sets `graduatedAt` and, if the token was the first to ever mint
   its name/symbol objects and is still within its first 24h, it holds those
   names for free during that window.
4. After the free window, the community can `extendReservation` — 1 ETH buys
   365 days of exclusive ownership over the name and ticker. Payments compound
   (the clock never resets down), capped at 100 years.

A graduated token that stops meeting the criteria loses its name on the next
challenge. Names are earned and defended, not assigned.

---

```
contracts/
├── Diggers.sol              Singleton launchpad (factory + router + fees + registry)
├── DiggersToken.sol         Launched-coin implementation (ERC20 + all token mechanics)
├── DiggersCoin.sol          $DIG platform coin (buy-mining airdrop)
├── DiggersRouter.sol        Universal V2/V3/V4 fee router for rescued tokens
├── interfaces/
│   ├── IDiggers.sol         Full external surface + events + errors
│   ├── IDiggersToken.sol    Token interface
│   ├── IDiggersCoin.sol     Platform coin interface
│   └── IDiggersRouter.sol   Fee router interface
└── libs/
    ├── DiggerV4.sol          Uniswap V4 pool plumbing
    ├── DiggerMath.sol        Fixed-point WAD/RAY math
    ├── DiggerCreateLib.sol   Token deployment + liquidity seeding
    ├── DiggerLaunchLiquidity.sol  Position minting
    ├── DiggerLaunchMath.sol  Start-price tick alignment
    ├── DiggerQuotes.sol      Buy/sell quoting (fee-inclusive)
    ├── DiggerSwapViews.sol   Pool-state reads via extsload
    ├── DiggerHarvestLib.sol  Fee collection + split logic
    ├── DiggerHarvestMath.sol Fee math (WAD splits)
    ├── DiggerHarvestViews.sol Pending-fee reads
    ├── DiggerRegistryLib.sol Name/symbol registry (contenders, reservations)
    ├── DiggerCharset.sol     On-chain charset validation + case folding
    ├── DiggerGraduationLib.sol Criteria checks + graduate()
    └── DiggerGraduationMath.sol Mean-tick mcap math
```

The tree is dependency-free: every import is relative, there are no external
packages, and everything compiles with `solc ^0.8.35`.

---

## Contract reference

### Diggers.sol — The Launchpad

The singleton that does everything: factory, swap router, V4 unlock-callback
host, LP fee harvester, pull-payment ledger, name/symbol registry, and
graduation engine. Every pool trades through this contract. It is the only LP
of every pool, and it has **no function to remove liquidity**.

#### Immutables & constants

| Name | Type | Description |
|---|---|---|
| `POOL_MANAGER` | `address` | The Uniswap V4 PoolManager all pools trade on |
| `PLATFORM_TOKEN` | `address` | $DIG — receives the 10% platform ETH slice during the airdrop |
| `TOKEN_IMPLEMENTATION` | `address` | The DiggersToken master copy; every launch is an EIP-1167 clone of it |
| `START_SQRT_PRICE_X96` | `uint160` | Launch sqrt price (Q64.96) — pump.fun-like ~1.33 ETH FDV for 1B supply |
| `START_TICK` | `int24` | Spacing-aligned tick matching the start price |
| `CREATION_FEE` | `uint256` | Flat creation fee (wei); runs a real buy that's burned so every pool has a first trade on-chain |

#### Ownership & protocol config

| Function | Access | Description |
|---|---|---|
| `owner()` | view | Current protocol owner (address(0) = renounced) |
| `feeRecipient()` | view | Team wallet that receives ETH fee credits |
| `teamShareWad()` | view | Global team share of ETH fees (1e18 = 100%) |
| `airdropStart()` / `airdropEnd()` | view | Unix bounds of the one-month airdrop window |
| `airdropActive()` | view | Whether the airdrop window is currently open |
| `startAirdrop()` | owner | Start the one-month airdrop (once only, irreversible) |
| `setTeamShareWad(uint256)` | owner | Set team share (≤100%; ≥10% while airdrop is live) |
| `setFeeRecipient(address)` | owner | Rotate the team ETH wallet |
| `transferOwnership(address)` | owner | Transfer protocol ownership |
| `renounceOwnership()` | owner | Renounce forever — all config functions are then dead |

#### Token creation

| Function | Access | Description |
|---|---|---|
| `create(TokenParams)` | payable | Deploy + seed a token. `msg.value` must cover `CREATION_FEE`; the remainder runs an initial buy to the creator. Simple overload — no custom fee table, no locks |
| `create(TokenParams, FeeSplit[], LockOrder[], uint256)` | payable | Full launch: deploy + seed + custom fee-split table + initial buy + distribute tokens across up to 10 recipients with optional tranche vesting — all in one tx |

**`TokenParams` struct:**
- `name` / `symbol` / `metadataURI` — identity (charset-validated on-chain)
- `lpFeeWad` — pool fee, exactly 1–5% (1e16 to 5e16, 1e18-scaled)
- `burnShareWad` — token-side harvest burn share (0–100%, rest goes to daily pot)
- `owner` — initial holder of both per-token owner roles (address(0) = renounced from birth)

**`LockOrder` struct:**
- `to` — recipient wallet
- `shareWad` — share of the initial buy output (all shares sum to 1e18)
- `tranches` — equal unlock slices (0 = unlocked, 1 = cliff, N = linear)
- `duration` — vesting duration in seconds

#### Trading (swap router)

| Function | Access | Description |
|---|---|---|
| `buy(token, minOut, to)` | payable | Buy tokens with exact ETH. Output goes to `to` (or `msg.sender` if zero). Mandatory slippage floor |
| `sell(token, amountIn, minOut, to)` | external | Sell tokens for ETH. **No approve needed** — the launchpad pulls directly from the caller. Mandatory slippage floor |
| `buyAndLock(token, minOut, LockOrder[])` | payable | Buy with ETH, then split + vest the purchased tokens across up to 10 recipients in one tx |
| `transferAndLock(token, amount, LockOrder[])` | external | Pull tokens from the caller and split + vest across up to 10 recipients (no pool leg, no points) |
| `quoteBuy(token, ethIn)` | view | Fee-inclusive quote: tokens out for exact ETH in |
| `quoteSell(token, amountIn)` | view | Fee-inclusive quote: ETH out for exact tokens in |

#### Fee harvesting & claims

| Function | Access | Description |
|---|---|---|
| `harvest(token)` | external | Collect accrued LP fees from the V4 pool and split: ETH → team + platform + creator table (pull credits). Tokens → burn share burned + remainder to daily pot |
| `claim()` | external | Withdraw your accumulated ETH fee credits |
| `ethOwed(account)` | view | Pull-payment ETH balance (wei) |
| `pendingFees(token)` | view | Uncollected LP fees awaiting the next harvest |
| `pendingEth(token)` | view | Creator ETH slices that failed delivery and await retry on next harvest |
| `feeSplitCount(token)` | view | Number of rows in the creator fee-split table |
| `feeSplitAt(token, index)` | view | One row of the creator fee-split table |

#### Per-token ownership

Each launched token has **two independent owner roles** (fee-split owner and burn
owner), both set at creation and separately transferable or renounceable.

| Function | Access | Description |
|---|---|---|
| `feeOwner(token)` | view | Who can edit the ETH fee-split table (zero = renounced) |
| `burnOwner(token)` | view | Who can edit the burn/airdrop split (zero = renounced) |
| `setFeeSplits(token, FeeSplit[])` | feeOwner | Replace the creator ETH fee-split table (1–10 rows, shares sum to 1e18) |
| `setBurnShare(token, burnShareWad)` | burnOwner | Update the token-side burn share (1e18-scaled, ≤100%) |
| `transferFeeOwnership(token, newOwner)` | feeOwner | Transfer fee-split ownership |
| `renounceFeeOwnership(token)` | feeOwner | Renounce forever — table freezes, fees keep flowing |
| `transferBurnOwnership(token, newOwner)` | burnOwner | Transfer burn-share ownership |
| `renounceBurnOwnership(token)` | burnOwner | Renounce forever — burn share freezes, fees keep flowing |

#### Name registry & graduation

| Function | Access | Description |
|---|---|---|
| `extendReservation(token)` | payable | Pay to extend a graduated token's name + ticker reservation. 1 ETH = 365 days, 100-year cap. Permissionless (anyone can pay). Proceeds → team pull ledger |
| `isNameFree(name)` | view | Whether a name could be used right now (its reservation lapsed) |
| `isSymbolFree(symbol)` | view | Whether a ticker could be used right now |
| `keyStateOf(name, symbol)` | view | Full registry state for both objects (reservationUntil, firstMinter, contenders) |
| `tokenKeys(token)` | view | The two registry objects a token holds (folded name + folded symbol) |
| `graduatedAt(token)` | view | When the token graduated (unix seconds; 0 = never) |
| `graduate(token)` | external | Graduate a token once it meets all three criteria. Permissionless. Usually automatic on trades, but this is the explicit path |
| `graduationProgress(token)` | view | Full progress: holders, volumeEth, avgMcapEth, window timing, and which criteria pass |

#### Pool views

| Function | Access | Description |
|---|---|---|
| `isDiggersToken(token)` | view | Whether this address was launched through the launchpad |
| `tokenRecord(token)` | view | On-chain pool record: creator, poolId, tick bounds, fee, burnShareWad |
| `poolState(token)` | view | Live pool snapshot: sqrtPriceX96, tick, liquidity, ethInPool, tokenInPool |
| `createNonce()` | view | Monotonic nonce used in CREATE2 salts |
| `poolManager()` | view | The V4 PoolManager address |

---

### DiggersToken.sol — The Launched Coin

The ERC-20 implementation that every launch is a clone of. Fixed 1 billion supply,
18 decimals, burnable, non-mintable. Everything beyond vanilla ERC-20 lives in the
`_update` pipeline — a single codepath that runs on every transfer, mint, and burn:

1. **24h anti-whale cap** — no wallet can hold >2% of supply for the first day
2. **Approve-free sells** — `transferFrom` skips the allowance when the launchpad calls
3. **Digging points** — pool buys earn 2e18·amount/supply, pool sells earn 5e17·amount/supply
4. **Top-10 leaderboard** — min-slot replacement, no sorting needed
5. **Lazy epoch settlement** — first transfer past `epochEnd` distributes the pot
6. **Graduation telemetry** — holderCount, volumeEthCum, dailyTick (pool legs only)
7. **Vesting lock enforcement** — post-transfer balance ≥ lockRemaining

#### ERC-20 core

| Function | Access | Description |
|---|---|---|
| `name()` | view | Token name (set at initialize) |
| `symbol()` | view | Token ticker (set at initialize) |
| `decimals()` | pure | Always 18 |
| `totalSupply()` | view | Current supply (decreases on burn, never increases) |
| `balanceOf(account)` | view | Token balance |
| `transfer(to, amount)` | external | Standard transfer (runs the full `_update` pipeline) |
| `approve(spender, amount)` | external | Standard ERC-20 approval |
| `allowance(owner, spender)` | view | Standard allowance |
| `transferFrom(from, to, amount)` | external | Standard transferFrom — **except** when `msg.sender` is the launchpad, the allowance check is skipped entirely. No allowance to revoke, no approve tx needed |
| `burn(amount)` | external | Burn tokens from the caller, reducing supply forever. Locked balances cannot be burned |

#### Initializer

| Function | Access | Description |
|---|---|---|
| `initialize(name, symbol, metadataURI, poolFee)` | launchpad only | Arms a fresh clone: sets identity, pool config, epoch clock, and mints the entire supply to the launchpad. Once only — an unarmed clone never exists on-chain |

#### Vesting locks

| Function | Access | Description |
|---|---|---|
| `registerLock(holder, total, duration, tranches)` | launchpad only | Register a tranche lock. Tokens stay in the wallet; only movement is gated. One lock per address, max 10 per token |
| `lockRemaining(holder)` | view | How much of `holder`'s balance is still locked right now |
| `getLock(holder)` | view | Full lock detail: total, start, duration, tranches, unlocked, remaining |
| `getLocks()` | view | Every lock on this token (up to 10 entries) |

#### Digging points & daily contest

| Function | Access | Description |
|---|---|---|
| `epoch()` | view | Current epoch id (bumps on each lazy settlement) |
| `epochEnd()` | view | Deadline of the current epoch — the first transfer past it triggers settlement |
| `traderPoints(trader)` | view | Points of `trader` in the current epoch |
| `pointsOf(epochId, trader)` | view | Points of `trader` in any epoch (current or past) |
| `lifetimePoints(trader)` | view | All-time points across every epoch (never reset) |
| `currentLeaders()` | view | Current epoch's top-10 board with scores |
| `leadersOf(epochId)` | view | Top-10 board for any epoch (boards are never cleared) |

#### Graduation telemetry

| Function | Access | Description |
|---|---|---|
| `holderCount()` | view | Unique pool-verified holders (pool buys add, zeroing removes) |
| `isCountedHolder(account)` | view | Whether `account` is in the holder count |
| `volumeEthCum()` | view | Cumulative ETH-equivalent pool volume (wei) |
| `dailyTickOf(dayIndex)` | view | A day's closing tick and whether it traded |
| `graduationStats()` | view | Snapshot: holders, volume, mean daily tick, days tracked |
| `POOL_ID()` | view | Deterministic V4 pool id for this token |

#### Immutables

| Name | Type | Description |
|---|---|---|
| `LAUNCHPAD` | `address` | The Diggers launchpad (factory, router, sole LP) |
| `POOL_MANAGER` | `address` | The V4 PoolManager this token trades on |
| `DEPLOYED_AT` | `uint64` | Launch timestamp — anchors the 24h whale cap and graduation windows |
| `metadataURI()` | `string` | IPFS URI of the launch metadata JSON (description, image, links) |

---

### DiggersCoin.sol — The $DIG Platform Coin

The buy-mining airdrop token. During the 30-day airdrop window, every pool buy on
any Diggers-launched token mints $DIG to the buyer. The mint rate starts at ~100 DIG
per ETH of platform fee and halves every 7 days. After the window closes, anyone
can call `finalize()` to:

1. Pair 10% of supply with the accrued ETH into a Uniswap V2 pool
2. Burn the LP tokens forever
3. Mint 50% of the final supply to the team treasury
4. Freeze supply and unlock transfers

#### Lifecycle

| Function | Access | Description |
|---|---|---|
| `init(diggers)` | deployer only | Wire in the launchpad (breaks the circular deploy dependency). Once only |
| `setMintTeamWallet(newWallet)` | launchpad owner | Rotate the wallet that receives the 50% finalize mint |
| `creditBuy(to, potEthWei)` | token only | Mint airdrop coins to a buyer. Called by each token's pool leg during the window. Silently mints nothing on zero input so buys are never bricked |
| `finalize()` | permissionless | Close the airdrop: claim ETH, mint team + LP share, pair on V2, burn LP, unlock transfers, freeze supply. Once only, after the window |

#### ERC-20

| Function | Access | Description |
|---|---|---|
| `name()` | pure | `"Diggers"` |
| `symbol()` | pure | `"DIG"` |
| `decimals()` | pure | `18` |
| `totalSupply()` / `balanceOf(account)` | view | Standard (transfers locked until finalized) |
| `transfer` / `transferFrom` / `approve` / `allowance` | external | Standard ERC-20 (transfers revert with `TransfersLocked` until finalized) |
| `burn(amount)` | external | Burn tokens from the caller |

#### Projections & views

| Function | Access | Description |
|---|---|---|
| `currentRate()` | view | Coins minted per 1 ETH of platform fee right now (halves weekly). Returns 0 after window |
| `projectedFinalSupply()` | view | What total supply would be if finalize ran now (2.5× airdropped) |
| `impliedPriceWeiPerToken()` | view | Implied wei per coin at the future V2 LP price |
| `holdingValueEth(user)` | view | ETH value of a user's holding at the implied LP price |
| `airdropSecondsLeft()` | view | Seconds remaining in the airdrop window (0 once ended) |
| `airdroppedSupply()` | view | Cumulative coins minted during the airdrop |
| `totalPotEthEstimated()` | view | Cumulative estimated platform ETH backing |
| `finalized()` | view | Whether finalize has been called |
| `launchpad()` | view | The Diggers launchpad address |
| `mintTeamWallet()` | view | Current team wallet for the finalize mint |
| `V2_ROUTER()` | view | Uniswap V2 Router used for the LP pairing |

---

### DiggersRouter.sol — The Universal Fee Router

A thin ETH↔token trade wrapper over external AMMs (Uniswap V2, V3, and V4 hookless
pools) that skims a small ETH-side fee to the team treasury. Built to give rescued
"dead community" tokens a trading home — the first users are the 69 Noxa launcher
tokens rescued onto Diggers, all trading on V3 1% pools.

#### Trading

| Function | Access | Description |
|---|---|---|
| `buy(token, venue, pool, minOut, deadline, recipient)` | payable | Buy tokens with ETH. Fee skimmed from `msg.value` first. Supports V2, V3, and V4 pools |
| `sell(token, venue, pool, amountIn, minOut, deadline, recipient)` | external | Sell tokens for ETH. Requires a prior ERC-20 approval. Fee skimmed from ETH output |

**`Venue` enum:** `V2` · `V3` · `V4`

#### Fee management

| Function | Access | Description |
|---|---|---|
| `sweep()` | permissionless | Send all accrued fees to the current `feeRecipient` |
| `setFeeWad(newFeeWad)` | owner | Set the fee rate (1e18-scaled, capped at `MAX_FEE_WAD`) |
| `setFeeRecipient(newRecipient)` | owner | Rotate the fee recipient |
| `transferOwnership(newOwner)` | owner | Transfer or renounce ownership (address(0) freezes fee forever) |

#### Views

| Function | Access | Description |
|---|---|---|
| `feeWad()` | view | Current fee rate (1e18-scaled) |
| `MAX_FEE_WAD()` | view | Immutable maximum fee the owner can ever set |
| `owner()` | view | Current owner (address(0) = renounced, fee frozen) |
| `pendingFees()` | view | Accrued unswept ETH fees |
| `feeRecipient()` | view | Where `sweep()` sends fees |
| `poolFor(token, feeTier)` | view | V3 pool address for a token + fee tier |
| `V2_FACTORY()` / `V3_FACTORY()` / `POOL_MANAGER()` / `WETH()` | view | Pinned Uniswap infrastructure addresses |

---

## Events (indexer contract)

The Diggers launchpad is the **single log address** for the entire protocol. All
non-ERC20 token events are re-emitted by the launchpad via the guarded `log*`
callback hub, so an indexer subscribes to one address only (plus each token's
plain ERC-20 Transfer/Approval).

<details>
<summary><strong>Full event list</strong></summary>

| Event | Description |
|---|---|
| `Created(token, creator, name, symbol, metadataURI, poolId, startSqrtPriceX96, poolFee, burnShareWad)` | A new token was deployed, pool initialized, liquidity seeded |
| `FeeSplitConfigured(token, recipients[], shares[])` | Creator ETH fee table set at creation |
| `FeeSplitUpdated(token, recipients[], shares[])` | Fee table replaced by the fee owner |
| `BurnShareUpdated(token, burnShareWad)` | Burn share changed by the burn owner |
| `FeeOwnershipTransferred(token, prev, new)` | Fee-split owner changed/renounced |
| `BurnOwnershipTransferred(token, prev, new)` | Burn-share owner changed/renounced |
| `FeeParked(token, recipient, amount)` | ETH delivery failed, retried on next harvest |
| `Swapped(token, trader, isBuy, ethAmount, tokenAmount, sqrtPriceAfter, tickAfter, liquidityAfter, ethInPool, tokenInPool)` | Router swap settled with full post-trade state |
| `Harvested(token, caller, ethTotal, ethToTeam, ethToPlatform, ethToCreators, tokensBurned, tokensToPot)` | LP fees collected and split |
| `Claimed(account, amount)` | Pull-payment ETH claimed |
| `Contender(nameKey, symbolKey, token, launchLockUntil)` | Token created, registry objects locked for 1h |
| `ReservationExtended(nameKey, symbolKey, token, payer, ethPaid, nameUntil, symbolUntil)` | Reservation extended on both objects |
| `Graduated(token, nameKey, symbolKey, holders, volumeEthCum, avgMcapEth)` | Token graduated (criteria met) |
| `PoolTrade(token, trader, isBuy, tokenAmount, ethValue, tick, holdersAfter, volumeEthCumAfter, epoch)` | Primary trade feed for graduation telemetry |
| `PointsCredited(token, epoch, trader, isBuy, pointsEarned, newScore, lifetimeScore)` | Points earned on a pool leg |
| `LeaderboardChanged(token, epoch, entrant, evicted, entrantScore)` | Top-10 board membership changed |
| `HolderCountChanged(token, holder, added, holderCountAfter)` | Unique holder counter changed |
| `EpochSettled(token, epoch, potPerWinner, rolledOver, nextDeadline)` | Daily pot distributed |
| `AirdropPaid(token, epoch, winner, amount)` | One winner received their pot share |
| `LockSet(token, holder, total, start, duration, tranches)` | Vesting lock registered |
| `OwnershipTransferred(prev, new)` | Protocol owner changed |
| `AirdropStarted(start, end)` | Platform airdrop window opened |
| `TeamShareUpdated(teamShareWad)` | Global team share changed |
| `FeeRecipientUpdated(feeRecipient)` | Team wallet rotated |

</details>

---

## Internal libraries

The `libs/` directory contains the protocol's internal plumbing — external
`library` contracts that the launchpad `delegatecall`s into. They are not
user-facing but are documented here for auditors and contributors.

| Library | Purpose |
|---|---|
| **DiggerV4** | Uniswap V4 pool plumbing: `encodePriceSqrt`, pool key construction, unlock callback helpers |
| **DiggerMath** | Fixed-point WAD/RAY arithmetic: `mulWad`, `divWad`, `mulDiv`, `sqrt` |
| **DiggerCreateLib** | Token deployment pipeline: clone creation, supply minting, pool init, liquidity seeding, fee-split setup |
| **DiggerLaunchLiquidity** | V4 position minting: single-sided token liquidity over `[startTick, MAX_TICK]` |
| **DiggerLaunchMath** | Start-price tick alignment: computes the spacing-aligned tick from a desired start price |
| **DiggerQuotes** | Buy/sell quoting: fee-inclusive token or ETH output from cached pool state (view-only) |
| **DiggerSwapViews** | Pool-state reads via `extsload`: reads sqrtPriceX96, tick, liquidity directly from PoolManager storage slots |
| **DiggerHarvestLib** | Fee collection: collects V4 LP fees, splits ETH (team/platform/creator table), handles token-side (burn/pot), manages pull credits and retry pots |
| **DiggerHarvestMath** | Fee math: WAD-scaled splits, platform slice carving |
| **DiggerHarvestViews** | Pending fee reads: queries uncollected fees from PoolManager without collecting |
| **DiggerRegistryLib** | Name registry: case-folded key creation, contender append, reservation extension, first-minter tracking, launch-lock enforcement |
| **DiggerCharset** | Charset validation: on-chain byte-level validation of names (1–32 chars, ASCII + single internal spaces) and symbols (1–10 chars, alphanumeric), case folding |
| **DiggerGraduationLib** | Graduation engine: criteria check (holders/volume/mcap), graduate state transition, auto-reserve on first-minter graduation |
| **DiggerGraduationMath** | Mean-tick mcap: computes the mean daily-close tick over ≤7 non-empty days and the ETH market cap it implies |

---

## Integrations

Aggregators, wallets, and portfolio trackers — see
[**INTEGRATIONS.md**](./INTEGRATIONS.md) for public REST endpoints (token info,
Uniswap token list), deployed contract addresses, on-chain metadata, and
graduation criteria.

## Building

The sources have no framework coupling. To compile them, drop `contracts/` into
any Foundry or Hardhat project (or use `solc` directly) with `solc ^0.8.35`,
`viaIR`, and the optimizer enabled.

## License

Business Source License 1.1 — see [LICENSE](./LICENSE).

The Licensed Work is (c) 2026 `diggersdotfun.eth` and is owned exclusively by the
holder of that ENS name. You may build on, integrate with, and earn from the
official Diggers deployment; you may not fork, redeploy, or counterfeit the
protocol. On the Change Date the code converts to GPL-2.0 or later. The
authoritative parameters live as ENS text records under `diggersdotfun.eth`.
