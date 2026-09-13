# Ladder Strategy — Spec

An accumulation strategy on 1inch Aqua. Holds USDC, buys the volatile asset on
the way down, sells above cost, sweeps realized proceeds out.

Architecture is a **Manager** plus exactly **two immutable child proxies** —
one buy side, one sell side. Each is deployed once and reused for the life of
the protocol, docking and re-shipping its strategy as the ladder moves.

Rebalancing prefers the cheapest operation that achieves the target:

- **Growing a position** — `push` raises the declared balance in place. No
  dock, no re-ship, one call.
- **Closing a position** — `dock` zeroes the declared balances so the strategy
  stops quoting, leaving nothing unfillable behind.

Measured on Base: ship ~82k gas, dock ~35k, push ~57k. All are negligible in
absolute terms; observed fee variance between transactions was driven almost
entirely by gas price (a 341x base-fee spike), not by which operation ran. Do
not optimise the choice of operation for gas — cap the keeper's max fee
instead.

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

## 3. Why two proxies, not many

An earlier design deployed one proxy per rung range and kept every strategy
alive, moving capital between proxies rather than docking. That existed to
avoid docking, on the assumption docking was expensive.

Measurement removed the assumption: ship ~82k gas, dock ~35k, push ~57k. The
expensive transactions were expensive because of a 341x base-fee spike, not the
operation. A full dock-and-reship cycle costs a fraction of a cent on Base.

Two permanent proxies are therefore strictly simpler: no registry, no factory,
no per-rung-range mappings, no deploy cost when the ladder shifts, and the
accounting watches two fixed addresses instead of a growing set. Nothing is
lost — rungs within a proxy were never independently funded anyway, since they
all draw on that proxy's single declared balance (Section 9).

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

Keeper-triggered. Distinct from a **harvest** (Section 12), which is a lighter
operation the keeper may run at any time between rebalances.

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
- **Emergency dock.** A Manager-triggered dock across all proxies stops all
  quoting immediately. It cuts losses; it does not book profit or close a round
  trip. Note it is terminal for those strategy bytes (Section 11).
- **Sweep without dock.** Sweeping tokens out does not touch Aqua, so the
  declared balance stays stale and the strategy keeps quoting depth the proxy
  cannot honour. Fills then revert at `Aqua.pull`. This is accepted by design
  for harvests (Section 12); it is only a hazard when a proxy is being retired,
  so **dock before retiring**.

## 11. Aqua balance semantics

Verified against `1inch/aqua` `src/Aqua.sol` and `1inch/swap-vm`
`contracts/instructions/XYCConcentrate.sol`.

### The declared balance drives the curve

`ship` stores exactly the amounts declared, with no reference to the maker's
wallet: `balance.store(amounts[i].toUint248(), tokensCount)`. The router reads
that value into the VM context (`SwapVM.sol:163`, via `AQUA.safeBalances`), and
`XYCConcentrateSwap.exec` derives `liquidity` from it.

So the declared amount is not a cap — it sets the depth of the curve. Declaring
more than the proxy holds makes it quote as though it were deeper, at prices it
cannot honour; the failure surfaces later as a revert in `Aqua.pull`.

**Rule: the declared balance must always equal the proxy's real balance.**

### What can change a declared balance

| Operation | Effect | Caller |
|---|---|---|
| `ship` | sets the initial amounts | maker |
| `push` | **increases** by `amount` | anyone |
| `pull` | decreases | the app only |
| `dock` | zeroes, marks docked | maker |

There is no maker-callable decrement. Reducing a position requires `dock`.

### push is unpermissioned

`push` checks only that the strategy is active — not that `msg.sender` is the
maker. This is required: it is the path the router uses to deliver a taker's
input tokens. Credit and transfer are the same number in the same call, so a
third party pushing to our strategy donates real tokens and cannot steal.

Two consequences:

- **Self-push.** When maker and `msg.sender` are the same contract, the
  transfer is a self-transfer moving nothing while the declared balance rises.
  This is how `LadderProxy.topUp` works.
- **Donations corrupt net-delta accounting.** An unsolicited push increases a
  proxy's balance with no offsetting movement, which Section 8's collapse reads
  as free acquisition and which drags `avgEntry` down. To book donations
  separately the Manager must read `Pushed` events and attribute by sender.

### Docking is terminal for the strategy bytes

`dock` sets `tokensCount` to `_DOCKED` (0xff). `ship` requires
`tokensCount == 0`. Nothing resets it. Since
`strategyHash = keccak256(strategy)` — the program bytes alone, with no maker
or nonce mixed in — **the same program can never be re-shipped by that maker.**

Re-shipping the same rung range therefore requires different bytes. Vary the
`Salt` instruction in the program to produce a distinct hash.

## 12. Harvesting partial fills

Ranged liquidity fills continuously, so a proxy accumulates the opposite token
long before its band is fully traversed. Waiting for a full rebalance to
collect that is unnecessary. **Harvesting is expected, routine behaviour**: at
any point, a keeper that detects a partial fill may poke the proxy and pull out
what it has acquired.

### Definition

A harvest transfers out the **acquired** token only:

| Proxy | Seed token (stays) | Acquired token (harvested) |
|---|---|---|
| Buy | USDC | WETH |
| Sell | WETH | USDC |

A harvest does exactly two things:

1. Transfer the acquired token out of the proxy to the Manager.
2. The Manager records the price paid for it.

It does **not** dock, does **not** re-ship, and does **not** top up. Top-ups
(Section 11) are a separate operation on their own schedule.

### Why no dock

Docking would be correct but unnecessary. The position is left quoting a
declared balance it can no longer honour on the harvested side, and any fill
that demands that token reverts at `Aqua.pull`. That is accepted: resolvers
simulate before routing, so a quote that cannot fill is simply not selected.
The seed side is unaffected and continues to fill normally.

Note the on-chain partial-fill clamp in `XYCConcentrateSwap.exec`
(`if (amountOut > balanceOut) amountOut = balanceOut`) clamps against the
**declared** balance, not the real one — so it does not protect here. The
protection is off-chain simulation, not the contract.

### Pricing is unaffected

The curve is computed solely from Aqua's declared balances
(`SwapVM.sol:163`, via `safeBalances`). A plain ERC-20 transfer out does not
touch them. A harvested proxy therefore quotes **exactly the same prices** as
an unharvested one — harvesting changes what can be delivered, never what is
quoted.

### Computing the price paid

Declared balances track fills automatically: each swap calls `pull` on the
outgoing token (`prevBalance - amount`) and `push` on the incoming one
(`prevBalance + amount`). No event parsing is required.

For a buy proxy, between ship and harvest:

```
usdcSpent   = declaredUsdcAtShip - declaredUsdcNow
wethAcquired = real WETH balance being harvested
pricePaid   = usdcSpent / wethAcquired
```

The Manager folds `usdcSpent` and `wethAcquired` into `costBasisUsdc` and
`inventoryBtc` exactly as in Section 8. Sell-side harvests are the mirror and
are booked as disposals.

**Caveat:** this arithmetic is only valid if nothing other than fills moved the
declared balance since the last observation. A `topUp` raises declared USDC
without a fill, and an unsolicited third-party `push` (Section 11) raises a
declared balance with no offsetting movement. The Manager must snapshot
declared balances immediately after any top-up, and treat a declared increase
on the seed side that it did not itself cause as a donation rather than a fill.

## 13. Strategy construction

The program shipped to Aqua is built from rung numbers inside the proxy, which
is the only contract holding both the ladder anchor and the side. Rung numbers
go in, bytes come out, and the bounds recorded on-chain are derived from the
same rungs that produced the bytes — so a mismatch between the declared range
and the encoded range is not representable.

### Encoding

Each instruction is `[opcode: 1 byte][argsLength: 1 byte][args: N bytes]`.
A program is instructions concatenated, with no header or terminator.

The opcode byte is an **index into the array returned by
`AquaOpcodes._opcodes()`** — a fixed-size array of function pointers — not an
enum value. This matters: `swap-vm` on `main` has refactored to an enum scheme
in `libs/OpcodeList.sol` with entirely different numbers. Deployed routers are
built from the tagged releases, so **use the array indices, not main's enum.**

### Instruction set

Verified against a live Base mainnet strategy and cross-checked with
`swap-vm` v1.0.1 `src/opcodes/AquaOpcodes.sol`:

| Opcode | Args | Instruction |
|---|---|---|
| `0x11` | 0 | `XYCSwap._xycSwapXD` |
| `0x12` | 64 | `XYCConcentrate._xycConcentrateGrowLiquidity2D` |
| `0x14` | 8 | `Controls._salt` |
| `0x15` | 4 | `Fee._flatFeeAmountInXD` |
| `0x1c` | 24 | `Fee._aquaProtocolFeeAmountInXD` |
| `0x21` | 20 | `Controls._onlyTxOriginTokenBalanceNonZero` |

### Program shape

```
concentrate(sqrtPriceMin, sqrtPriceMax)   grow virtual liquidity into the band
flatFeeIn(fee)                            deduct fee from amountIn
xycSwap()                                 compute amounts from balances
salt(nonce)                               no runtime effect; unique hash
```

### Salt

```
salt = uint64(keccak256(chainId, proxy, nonce))
```

`nonce` is proxy-local, monotonic, and advanced only inside `shipStrategy`.
Nothing external can move or reset it. This is what makes a permanent proxy
possible: docking is terminal for a given set of bytes, so every ship must
produce a distinct hash.

The Salt instruction carries a `uint64`, so the hash is truncated to 64 bits.
A collision only matters for the same maker and app, and fails loudly (`ship`
reverts with `StrategiesMustBeImmutable`) rather than corrupting state.

## 14. Failure policy

This is a hackathon build. Customisation and extensibility are explicitly
deprioritised in favour of fewer lines of code.

If a strategy misbehaves, the response is not to reconfigure it in place:

1. Emergency dock across both proxies, stopping all quoting.
2. Sweep all assets back to the Manager.
3. Shut the protocol down.
4. Redeploy with corrected strategies.

No in-place strategy repair, no migration path, no versioning. The two proxies
are cheap to redeploy and hold no state that cannot be reconstructed.
