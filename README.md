# Diggers V1 — smart contracts

Diggers is a fair launchpad on Robinhood Chain, built natively on Uniswap V4.
One transaction launches a coin with its entire 1 billion supply seeded as
locked, single-sided liquidity in a hookless V4 pool. No bonding curve, no
migration, no admin keys over balances or liquidity — the core mechanics are
immutable from the first block.

This repository contains the complete Solidity sources of the protocol.

- Website: https://diggers.fun
- ENS / Licensor: `diggersdotfun.eth`
- Official deployments: published at `v1-deployments.diggersdotfun.eth`

## Layout

```
contracts/
├── Diggers.sol            The singleton launchpad: factory, swap router,
│                          V4 unlock-callback host, fee splitter, and the
│                          on-chain name registry (contenders, reservations,
│                          blue-chip graduation).
├── DiggersToken.sol       The launched-coin implementation. Every launch is
│                          a 45-byte EIP-1167 minimal proxy of it: fixed
│                          1e9 supply, burnable, non-mintable, first-day 2%
│                          anti-whale cap, approve-free sells, digging
│                          points, the rolling 24h contest with lazy epoch
│                          settlement, tranche vesting locks, and graduation
│                          telemetry — all in one _update pipeline.
├── DiggersCoin.sol        $DIG, the platform coin: buy-mining airdrop over
│                          a 30-day window, then finalize, burn the LP,
│                          unlock transfers.
├── DiggersRouter.sol      Universal V2/V3/V4 fee router for rescued tokens.
├── interfaces/            IDiggers, IDiggersToken, IDiggersCoin,
│                          IDiggersRouter — the full external surface,
│                          including every event the indexer consumes.
└── libs/                  Internal libraries: V4 plumbing (DiggerV4),
                           fixed-point math (DiggerMath), launch seeding
                           (DiggerCreateLib, DiggerLaunchLiquidity,
                           DiggerLaunchMath), quoting (DiggerQuotes,
                           DiggerSwapViews), fee harvesting
                           (DiggerHarvest*), the name registry
                           (DiggerRegistryLib, DiggerCharset), and
                           graduation (DiggerGraduation*).
```

The tree is dependency-free: every import is relative, there are no external
packages, and everything compiles with `solc ^0.8.35`.

## Protocol in one minute

- **Launch.** `Diggers.create` deploys the token clone, mints the full
  supply to the launchpad, and seeds all of it as single-sided liquidity
  over `[startTick, MAX_TICK]` at a constant start price. Liquidity is never
  removable; only fees can be collected. ETH is `currency0`.
- **Trade.** Buys and sells route through the launchpad directly against the
  V4 PoolManager. Sells need no approval: the token trusts its launchpad
  under two hard-coded conditions (the tokens belong to the transaction
  signer, and the move is part of the sell flow).
- **Fees.** The pool fee is creator-chosen at launch (1%–5%). Harvested ETH
  splits 30% team / 70% creator fee table (up to 10 recipients, immutable,
  pull payments). The token side is partly burned (creator-chosen share) and
  partly parked as the daily contest pot.
- **Sniper Defense.** For the first 24 hours no wallet can hold more than 2%
  of supply. Enforced by the token contract itself on every transfer, then
  it lifts automatically.
- **Digging points.** Every pool trade scores points (buys weigh 4x sells);
  the top 10 of each rolling 24h epoch split the pot, settled lazily by the
  first transfer past the epoch end.
- **Names.** Name and ticker are case-insensitive registry keys. Every
  launch locks both for 1 hour; a first-minter coin that graduates inside
  its first 24 hours holds them free for that window; afterwards anyone can
  extend a live blue chip's reservation at 1 ETH per 365 days, up to 100
  years.
- **Graduation.** Purely criteria-based, no committee: 500+ holders,
  540+ ETH cumulative volume, and a 270+ ETH mean daily market cap. All
  three are measured on-chain from pool legs only.

## Integrations

Aggregators, wallets, and portfolio trackers — see
[INTEGRATIONS.md](./INTEGRATIONS.md) for public REST endpoints (token info,
Uniswap token list), deployed contract addresses, on-chain metadata, and
graduation criteria.

## Building

The sources have no framework coupling. To compile them, drop `contracts/`
into any Foundry or Hardhat project (or use `solc` directly) with
`solc ^0.8.35`, `viaIR`, and the optimizer enabled.

## License

Business Source License 1.1 — see [LICENSE](./LICENSE).

The Licensed Work is (c) 2026 `diggersdotfun.eth` and is owned exclusively
by the holder of that ENS name. You may build on, integrate with, and earn
from the official Diggers deployment; you may not fork, redeploy, or
counterfeit the protocol. On the Change Date the code converts to GPL-2.0
or later. The authoritative parameters live as ENS text records under
`diggersdotfun.eth`.
