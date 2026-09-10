# Ladder Strategy — Spec

An accumulation strategy on 1inch Aqua. Holds USDC, buys the volatile asset on
the way down, sells above cost, sweeps realized proceeds out.

Architecture is a **Manager** plus a set of **immutable child proxies**.
Strategies are shipped once per proxy and left alive; rebalancing moves
*capital between contracts* rather than docking and re-shipping, because
transfers are far cheaper than ship/dock.

## 1. Rungs

Prices live on a fixed geometric ladder anchored to an initial price `I`.

```
rung(1000) = I
rung(n)    = rung(n-1) * 1.025      for n > 1000
rung(n)    = rung(n+1) * 0.975      for n < 1000
```

Spacing is 2.5% up and ~2.56% down, so the ladder is not symmetric across
1000. Do not assume `rung(n+k)/rung(n)` is constant across the boundary.

Helpers:
- `rungBelow(p)` — highest rung whose price is <= `p`
- `rungAbove(p)` — lowest rung whose price is >= `p`

## 2. Contracts

### Manager
Owns all state and all decisions:
- tracks PnL, cost basis, and realized proceeds
- computes rung prices and target ladder placement
- performs Uniswap buys and sells directly
- holds **dry powder** (undeployed USDC)
- deploys buy/sell proxies and moves capital in and out of them

### Buy proxy
Seeded with USDC. Ships **6 concentrated range positions** covering rungs `rl`
down to `rl-5`. Rung set fixed at construction.

### Sell proxy
Seeded with BTC. Ships **6 concentrated range positions** covering rungs `rh`
up to `rh+5`. Rung set fixed at construction.

Proxies are dumb: they hold assets, hold shipped strategies, and transfer on
the Manager's instruction. They perform no accounting.

**Positions are ranged liquidity, not directional orders.** Like a Uniswap v3
LP position, each range quotes *both* directions and converts whichever asset
it holds as price moves through the band. "Buy" and "sell" describe where a
proxy's rungs sit and which asset seeds it — not a one-way constraint on how
it can fill. A range that converts and then converts back captures fees on
both legs; this is expected and desirable.

## 3. Proxy registry and reuse

The Manager keeps persistent mappings from ladder anchor to proxy:

```
maxRungToBuyProxy[rl]   -> buy proxy covering rungs rl .. rl-5
minRungToSellProxy[rh]  -> sell proxy covering rungs rh .. rh+5
```

On rebalance the Manager computes the target `rl` / `rh`, looks up the mapping,
and either reuses the existing proxy or deploys a new one and records it.
Reuse is expected to be uncommon within a single run — its main purpose is
re-running the strategy after a position closes out, so previously built
ladders can be picked back up without redeploying.

## 4. Asset segregation

**Only one asset type is ever transferred into a proxy** — USDC into buy
proxies, BTC into sell proxies. A proxy will nonetheless come to hold both as
price moves through its bands. That is normal and is not corrected until the
next rebalance, when the proxy is fully emptied.

Because every proxy starts each period holding exactly one asset, its net
delta over the period has a known sign:

- buy proxy: BTC delta >= 0, USDC delta <= 0
- sell proxy: BTC delta <= 0, USDC delta >= 0

## 5. Order placement (clamped)

Both sides are clamped against spot so no bid is ever above market and no ask
is ever below market.

```
buy:   rl = min( rungBelow(spot), rungBelow(avgEntry) )
       buy proxy covers rl, rl-1, ... rl-5

sell:  rh = max( rungAbove(spot), rungAbove(avgEntry) )
       sell proxy covers rh, rh+1, ... rh+5
```

When spot and `avgEntry` diverge, one side tracks spot and the other parks far
away and goes inert. This is expected.

## 6. Rebalance loop

Keeper-triggered. Strategies are **not** docked.

**Trigger conditions:**
- periodic, once per configured interval, or
- **early**, if spot exceeds the outermost rung on either side — i.e. spot
  falls below `rung(rl-5)` or rises above `rung(rh+5)`. Past that point the
  ladder no longer covers the market and quoting is dead until it moves.

**Phases:**

1. **Observe and account.** Read every proxy's balances, transfer all assets
   back to the Manager, compute each proxy's net delta, update cost basis and
   PnL.
2. **Trade.** Execute Manager-side Uniswap buys or sells.
3. **Re-account.** Recompute `avgEntry` and PnL including the Uniswap fills.
4. **Deploy.** Compute target `rl` / `rh` against current spot, resolve or
   deploy the target proxies, and transfer USDC to the buy proxy and BTC to
   the sell proxy for this round.

## 7. Keeper deposits

The keeper may add capital at a rebalance:

- **USDC** — increases buy-side capital. No cost-basis effect.
- **BTC** — must arrive with the USDC price it was acquired at. Both
  `inventoryBtc` and `costBasisUsdc` increase, so `avgEntry` updates as if the
  vault had bought it directly.

Deposits go to the Manager, never directly to a proxy. Assets sent directly to
a proxy are indistinguishable from fill flow and will be silently absorbed
into the cost basis at the next rebalance.

## 8. Accounting

All in the Manager. Aggregated across dry powder and every proxy.

| Field | Meaning |
|---|---|
| `costBasisUsdc` | USDC paid for currently held BTC |
| `inventoryBtc` | BTC currently held |
| `avgEntry` | `costBasisUsdc / inventoryBtc` |
| `realizedUsdc` | Lifetime proceeds swept to the profit vault |

### Net-delta collapse

A period's activity in a proxy — however many fills, in whichever directions —
is collapsed into **one trade**: the USDC delta against the BTC delta.

```
buy proxy:   acquired  = +BTC delta, paid     = -USDC delta
             costBasisUsdc += paid;  inventoryBtc += acquired

sell proxy:  disposed  = -BTC delta, received = +USDC delta
             cost of disposed slice = costBasisUsdc * disposed / inventoryBtc
             realized += received - that slice
             remove disposed and its slice proportionally
```

Round trips inside a period are therefore invisible: gains from a retrace are
absorbed into the effective price of the collapsed trade rather than booked
separately. This is intentional. It means a buy proxy's round-trip gains
lower `avgEntry` instead of reaching the profit vault, and total equity is
unaffected either way.

Selling removes a proportional slice of both `costBasisUsdc` and
`inventoryBtc`, so `avgEntry` is unchanged by sells. `avgEntry` falls only
when BTC is acquired.

### Reporting

- Realized: proceeds swept out. Permanently out of scope for PnL.
- Unrealized: `inventoryBtc` marked to spot, minus `costBasisUsdc`.

Realized alone is not a performance measure: profits leave permanently while
losses remain in inventory, so realized skews positive through arbitrarily
bad drawdowns. Report mark-to-market alongside it.

## 9. Capital allocation

Aqua's shared liquidity is scoped **per maker**. Each proxy is its own maker,
so a buy proxy's 6 ranges all quote against that proxy's single USDC balance.

**Consequence:** ranges within a proxy are not independently funded. The first
to fill can consume the whole balance, and a further fill on another range of
the same proxy reverts for lack of funds. Six rungs are six *price points at
which that proxy's balance may be spent*, not six separately funded orders.

Splitting capital across proxies is the only way to fund rungs independently.

## 10. Risk controls

- **Total deployed cap.** Every rung down requires more capital while profit
  leaves permanently. Without a hard cap this is a martingale bounded only by
  solvency.
- **Emergency dock.** Since the normal loop never docks, an explicit
  Manager-triggered dock across all proxies is the only way to stop quoting.
  It cuts losses; it does not book profit or close a round trip.
- **Stale strategies.** Proxies retain live strategies after their capital is
  withdrawn. They quote nothing while empty, but quote again the moment any
  asset is transferred in — intentional for reuse, hazardous if accidental.
