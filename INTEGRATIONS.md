# Integrations — Diggers on Robinhood Chain

This document describes the public, machine-readable integration surface for
aggregators, wallets, portfolio trackers, and any tool that wants to list or
display Diggers-launched tokens.

## Chain

| Property | Value |
|---|---|
| Chain ID | `4663` |
| Currency | ETH (native) |
| Explorer | https://robinhoodchain.blockscout.com |
| RPC (public, rate-limited) | `https://rpc.mainnet.chain.robinhood.com` |

## Deployed contracts (Deploy #8)

All contracts are **verified** on the Blockscout explorer.

| Contract | Address | Notes |
|---|---|---|
| **Diggers** (launchpad) | [`0x4190a197e9c7c8D9ce1095c32e6666A13A996580`](https://robinhoodchain.blockscout.com/address/0x4190a197e9c7c8D9ce1095c32e6666A13A996580) | Singleton factory, swap router, fee splitter, name registry |
| **DiggersCoin** ($DIG) | [`0x4a64812C952C4684cB0C5169d57f3D0F95dC06e2`](https://robinhoodchain.blockscout.com/address/0x4a64812C952C4684cB0C5169d57f3D0F95dC06e2) | Platform coin (buy-mining airdrop) |
| **DiggersToken** (impl) | [`0xE15A52D171D655cFBA30D64C94821bE4cf623dD9`](https://robinhoodchain.blockscout.com/address/0xE15A52D171D655cFBA30D64C94821bE4cf623dD9) | EIP-1167 clone source — every launched token is a minimal proxy of this |

Every launched token is an EIP-1167 minimal proxy clone of the DiggersToken
implementation. Once the implementation is verified, Blockscout auto-matches
all clones as verified proxies.

## REST API endpoints

Base URL: `https://diggers.fun`

### Token info (DexScreener-shaped)

**`GET /api/token-info/{address}`** — full detail for one token.

Response fields:

```json
{
  "chainId": 4663,
  "tokenAddress": "0x...",
  "name": "...",
  "symbol": "...",
  "decimals": 18,
  "totalSupply": "1000000000000000000000000000",
  "icon": "https://...",
  "openGraph": "https://diggers.fun/api/og/token/0x...?v=cover",
  "description": "...",
  "metadataUri": "ipfs://...",
  "links": [{ "type": "twitter", "label": "X (Twitter)", "url": "https://..." }],
  "url": "https://diggers.fun/coin/0x...",
  "creator": "0x...",
  "createdAt": 1784149925,
  "priceEthPerToken": 0.00000000133,
  "mcapUsd": 3456.78,
  "volume24hEth": 12.5,
  "launchpad": {
    "graduated": false,
    "atRisk": false,
    "progressPct": 42,
    "holders": 210,
    "holdersTarget": 500,
    "volumeEth": 230,
    "volumeTargetEth": 540,
    "avgMcapEth": 120,
    "mcapTargetEth": 270
  },
  "pool": {
    "dexId": "uniswap-v4",
    "poolId": "0x...",
    "feeMillionths": 10000
  }
}
```

**`GET /api/token-info?limit=100&offset=0`** — paged list (lighter shape,
no links/pool/launchpad fields).

Both routes: CORS `Access-Control-Allow-Origin: *`,
`Cache-Control: public, s-maxage=60, stale-while-revalidate=300`.

### Uniswap Token List

**`GET /tokenlist.json`** — standard
[Uniswap token-list schema](https://uniswap.org/tokenlist.schema.json).

Every tradable Diggers token with chain ID `4663`, address, name, symbol,
decimals (18), logoURI, and extensions (`graduated`, `launchpad: "diggers"`).

CORS `*`, `Cache-Control: public, s-maxage=300, stale-while-revalidate=3600`.

## On-chain metadata

Every DiggersToken exposes a public `metadataURI()` view that returns an IPFS
URI pointing to a JSON object with:

```json
{
  "name": "...",
  "symbol": "...",
  "description": "...",
  "image": "ipfs://...",
  "links": { "x": "https://...", "website": "https://...", "telegram": "https://..." }
}
```

The factory `Created` event carries the `metadataURI` at creation time, so
indexers can pick it up without an RPC call.

## Graduation criteria

A token graduates (locks its name and ticker) when **all three** are met:

1. **Holders** >= 500
2. **Cumulative volume** >= 540 ETH
3. **Mean daily market cap** >= 270 ETH

All measured on-chain from pool legs only (sybil defense).

## Contact

For launchpad integration partnerships (DexScreener, CoinGecko, portfolio
trackers): reach out via https://x.com/diggersdotfun or Telegram
https://t.me/diggersdotfun.
