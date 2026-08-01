// SPDX-License-Identifier: MIT

// what are our invariants?
//1. total supply of DSC should always be lower than the total value of collateral in the system
//2. getter view functions should never revert

pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDSC} from "script/DeployDSC.s.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Handler} from "./Handler.t.sol";

contract invariant is StdInvariant, Test {
    DeployDSC deployer;
    DSCEngine dsce;
    DecentralizedStableCoin dsc;
    HelperConfig config;
    Handler handler;
    address weth;
    address wbtc;

    function setUp() external {
        deployer = new DeployDSC();
        (dsce, dsc, config) = deployer.run();
        (weth, wbtc,,,) = config.activeNetworkConfig();
        // targetContract(address(dsce));
        handler = new Handler(dsce, dsc);
        targetContract(address(handler));
    }

    function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
        uint256 totalSupply = dsc.totalSupply();
        uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dsce));
        uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(dsce));

        // console.log("totalSupply: ", totalSupply);
        // console.log("totalWethDeposited: ", totalWethDeposited);
        // console.log("totalWbtcDeposited: ", totalWbtcDeposited);
        // console.log("timesMintIsCalled: ", handler.timesMintIsCalled());

        uint256 wethValue = dsce.getUsdValue(weth, totalWethDeposited);
        uint256 wbtcValue = dsce.getUsdValue(wbtc, totalWbtcDeposited);

        assert(wethValue + wbtcValue >= totalSupply);
    }

    function invariant_gettersShouldNotRevert() public view {
        for (uint256 i = 0; i < handler.getDepositedUserCount(); i++) {
            address user = handler.userWithCollateralDeposited(i);
            dsce.getAccountInformation(user);
            dsce.getHealthFactor(user);
            dsce.getCollateralBalanceOfUser(user, weth);
            dsce.getCollateralBalanceOfUser(user, wbtc);
        }

        dsce.getCollateralTokenPriceFeed(address(weth));
        dsce.getCollateralTokenPriceFeed(address(wbtc));
        dsce.getCollateralTokens();
        dsce.getUsdValue(weth, 100e18);
        dsce.getUsdValue(wbtc, 100e8);
        dsce.getMinimumHealthFactor();
    }

    function invariant_noUserWithDebtShouldEverHaveBrokenHealthFactor() public view {
        for (uint256 i = 0; i < handler.getDepositedUserCount(); i++) {
            address user = handler.userWithCollateralDeposited(i);
            (uint256 totalDscMinted,) = dsce.getAccountInformation(user);
            if (totalDscMinted > 0) {
                uint256 healthFactor = dsce.getHealthFactor(user);
                assert(healthFactor >= dsce.getMinimumHealthFactor());
            }
        }
    }

    function invariant_debtShouldEqualActualTokenSupply() public view {
        uint256 totalSupply = dsc.totalSupply();
        uint256 totalDebt;
        for (uint256 i = 0; i < handler.getDepositedUserCount(); i++) {
            address user = handler.userWithCollateralDeposited(i);
            (uint256 totalDscMinted,) = dsce.getAccountInformation(user);
            totalDebt += totalDscMinted;
        }
        assertEq(totalDebt, totalSupply);
    }
}
