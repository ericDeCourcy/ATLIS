

// contact manager 

    // from both of these, we can compute a price-per-coin on the fly
        // uint public totalWethPurchased
        // uint public totalUSDCPaid

    // uint TAX_PCT
    // address PROFIT_DEST
    // address TAX_DEST
    // constant REBALANCE_PERIOD //num seconds between rebalances
    // uint lastRebalance
    // uint USDCSentToBuy     // on last rebalance, this was the amount given to the buy proxy to use to buy
    // uint WETHSentToSell      // on last rebalance, this was the amount of WETH we sent to the proxy to sell


    // function harvest 
        // this will pull "new" tokens from both the buy and sell strategies
    
    // function getAvgPrice
        // totalWethPurchased / totalUSDCPaid

    // function rebalance
        // assert that blockTimestamp > lastRebalance + REBALANCE_PERIOD
        // _dockProxies()


    // function _dockProxies()
        // first dock any WETH sells...
            // 

    // function _dockSells()
        // end strategy and dock it
        // transfer tokens to the manager, checking balance before and after to determine token deltas
        // if WETH recieved back is less than WETHSentToSell...
            // compute difference here (this is weth actually sold)
            // take the USDC amount recieved, use it to _accountSale
                // TODO: here, i'm not sure if we're double counting if we have WETHSentToSell and totalWethPurchased.... hmmm
        // WETH recived back is MORE than WETHSentToSell...
            // thats a donation
                // sell somehow... TODO define this behavior
    

    // function _accountPurchase(newWETH, paidUSDC)
        // this exists to account for weth purchases 
            // simply adds to `totalWethPurchased` and `totalUSDCPaid`
    
    // function _accountSale(soldWeth, proceeedsUSDC)
        // this exists to account for weth sales
        // amountPaid = based on "soldWeth", compute the amout paid via `getAvgPrice`
        // rawprofit = proceedsUSDC - amountPaid;
        // taxAmount = rawProfit * TAX_PCT / 100;
        // transer taxAmount of USDC to tax wallet
        // decrease totalWethPurchased by soldWeth 
        // decrease totalUSDCPaid by amountPaid from earlier
    
    // function _createBuyStrategy(amount)
        // finds nearest rung to getAvgPrice
        // pick correct rungs for buy strategy limits
        // transfer `amount` into the proxy
        // set the strategy on the proxy
    
    // function _createSellStrategy()
        // notice, no amount. This is because all WETH is up for sale
        // pick the correct rungs for sell strategy (see spec)
        // transfer weth into proxy
        // set the strategy on the proxy
