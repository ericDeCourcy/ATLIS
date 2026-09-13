# ATLIS

"ATLIS" stands for "**A**qua **T**ime-decaying **L**addered **I**nvestment **S**trategies.

The general idea is that ATLIS will create an LP position over a price band for some asset pair, with the goal of accumulating one asset over time. Periodically, ATLIS will rebalance your position, selling small portions of the volatile asset while in profit.

ATLIS will track PnL automatically and divert some portion of profits into a "tax-savings" wallet for ease of use.

# Integrations

1inch Aqua

# USDC-BTC pair

The first iteration of ATLIS will specifically focus on the BTC/USDC pair, with the intention of using USDC to buy and sell BTC and gain more USDC.

We will actually be using USDC and WBTC at first, because BTC is not natively available. 

# How it works

0. (#TODO not sure about this yet) ATLIS will market-buy some amount of BTC to seed the strategy
1. Every "period", ATLIS will determine how much USDC to invest into the strategy. This increases over time as the strategy goes on. ATLIS will take the current BTC price and determine a price-band to LP for. 
2. During the period, BTC price will fluctuate in price. If BTC price goes up, ATLIS will sell some BTC held by the strategy. Otherwise, it will buy BTC at a price below the spot price at the beginning of the period
3. At the end of the period, ATLIS will "dock" the position out of Aqua and examine the balances. 
    a. If BTC price is sufficiently higher than the "average entry" price for the position, a portion will be sold and the profits from the sale will be optionally transferred to a "profit", "tax" and "principle" wallet.
    b. If BTC price is sufficiently lower than the "average entry" price for the position, more USDC will be deployed into the strategy, optionally splitting it between a spot buy and adding to the LP position.
4. The next period begins, and ATLIS creates an LP position within a price band around the entry price (#TODO i think we need two diff LP positions for once spot and entry price diverge, because otherwise we might buy too high and sell too low).

# Yield sources

- Aqua incentives
- aUSDC


# Emergency exits


# Risks

### Emergency Withdrawal
Emergency withdrawal needs to be able to withdraw funds quickly and unconditionally, but also must not be publicly callable. This is needed in case a bug is discovered within Aqua or within the ATLIS strategy.

# Future development 
Implement Aave a-tokens for yield when assets are passive