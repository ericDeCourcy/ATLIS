# ATLIS

"ATLIS" stands for "**A**qua **T**ime-decaying **L**addered **I**nvestment **S**trategies.

The general idea is that ATLIS will create an LP position over a price band for some asset pair, with the goal of accumulating one asset over time. Periodically, ATLIS will rebalance your position, selling small portions of the volatile asset while in profit.

ATLIS will track PnL automatically and divert some portion of profits into a "tax-savings" wallet for ease of use.

# Integrations

- 1inch Aqua
- Uniswap V3
- Chainlink Oracle for WETH/USDC

# USDC-WETH pair

The first iteration of ATLIS will specifically focus on the WETH/USDC pair on Base Network, with the intention of using USDC to buy and sell WETH and gain more USDC.

# How it works

* There is an array of prices called the "ladder" (#TODO variable name here), based around $3000 at index `[1000]`. For every subsequent index, the price is 2.5% higher. For indices below 1000, the price is 97.5% the price of the one above it (these are slightly different, but not meaningfully so). 

1. ATLIS will market-buy some amount of WETH to seed the strategy
2. Every "period", ATLIS will rebalance. ATLIS will attempt to deploy X USDC every rebalance into the strategy, pulled from the total amount of USDC originally placed in the contract address. Eventually it will invest all USDC, and at this point the system will no longer add USDC. ATLIS will take the current WETH price and determine a price-band to LP for, and setup a "buy order" below the average purchase price currently recorded.
3. Upon rebalancing, ATLIS will recalculate the price band to sell WETH at a profit, and will setup a "sell order" across 
3. During the period, WETH price will fluctuate in price. If WETH price goes up, ATLIS will sell some WETH held by the strategy. Otherwise, it will buy WETH at a price below the spot price at the beginning of the period
4. At the end of the period, ATLIS will "dock" the position out of Aqua and examine the balances. 
    a. If WETH price is sufficiently higher than the "average entry" price for the position, a portion will be sold and the profits from the sale will be optionally transferred to a "profit", "tax" and "principle" wallet.
    b. If WETH price is sufficiently lower than the "average entry" price for the position, more USDC will be deployed into the strategy, optionally splitting it between a spot buy and adding to the LP position.
5. The next period begins, and ATLIS creates an LP position within a price band around the entry price (#TODO i think we need two diff LP positions for once spot and entry price diverge, because otherwise we might buy too high and sell too low).

# Yield sources

- Aqua incentives
- aUSDC


# Emergency exits


# Risks

### Emergency Withdrawal
Emergency withdrawal needs to be able to withdraw funds quickly and unconditionally, but also must not be publicly callable. This is needed in case a bug is discovered within Aqua or within the ATLIS strategy.

# Future development 
Implement Aave a-tokens for yield when assets are passive.

Implement a watcher via Chainlink that can harvest from either proxy.