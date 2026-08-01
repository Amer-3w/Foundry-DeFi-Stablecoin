// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/*
 *@title OracleLib
 *@author Amer k.
 *@notice this library is used to check the chainlink oracle for stale 
 *if a price is stale, the function will revert and render the DSCEngine unusable - this is by design
 * we want the DSEEngine to freeze if the prices become stale
 * if the chainlink network explodes having money locked in the protocol will be bad
 */

library OracleLib {
    error OracleLib__PriceIsStale();

    uint256 private constant STALE_PRICE_THRESHOLD = 10 hours; // is 10*60*60 = 36000 seconds

    function staleCheckLatestRoundData(AggregatorV3Interface priceFeed)
        public
        view
        returns (uint256, int256, uint256, uint256, uint80)
    {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            priceFeed.latestRoundData();

        uint256 secondsSinceLastUpdate = block.timestamp - updatedAt;
        if (secondsSinceLastUpdate > STALE_PRICE_THRESHOLD) {
            revert OracleLib__PriceIsStale();
        }
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}
