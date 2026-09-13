1. Look into "XYCConcentrate" - this is the strategy we are using
2. Add a license for free use
3. Add an audit disclaimer
4. Guard from doing long walks with the rung math - prevent differences that are really high 
5. Create the manager contract
    - reference the spec
    - should have a poke function which will do the following:
        - 1. First, withdraw all "bought" tokens and "sold" tokens
            - for USDC obtained from selling wbtc, see the balance delta to figure out how much wbtc was sold for that amount of USDC. Compute the profit based on the average buy price, then send funds to two places - profit vault and tax vault. Optionally reinvest principle or send principle to profit vault. 
        - 2. if rebalance time has occurred:
            - first dock and transfer all tokens to manager, recomputing all accounting
            - next increase "dry powder" available, by `min(newPowderPerPeriod, (USDC_balance) - dryPowder)`
            - next check uniswap price
                - if uniswap price is within lower window, spend `max(PURCH_PCT * dryPowder, MIN_BUY, dryPowder)` of capital on spot to buy BTC
                    - recompute avg buy price
                - else if uniswap price is within upper window, sell `max(DECAY_PCT * BTC_held, MIN_SELL, BTCHeld)`
                    - transfer profits and update accounting accordingly
            - next check the average buy price and compute rungs
            - next create new strategies and transfer assets to the proxies
            - reset countdown for next period
                 