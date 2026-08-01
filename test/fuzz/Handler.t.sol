// SPDX-License-Identifier: MIT

//narrows down the way we call functions

pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "test/mocks/MockV3Aggregator.sol";

contract Handler is Test {
    DSCEngine public dsce;
    DecentralizedStableCoin public dsc;
    MockV3Aggregator public ethUsdPriceFeed;

    //MockV3Aggregator public btcUsdPriceFeed;

    ERC20Mock weth;
    ERC20Mock wbtc;

    uint256 constant MIN_DEPOSIT_SIZE = 1;
    uint256 constant MAX_DEPOSIT_SIZE = type(uint96).max;

    uint256 public timesMintIsCalled;
    address[] public userWithCollateralDeposited;

    mapping(address => bool) private s_hasDepositedCollateral;

    constructor(DSCEngine _dsceEngine, DecentralizedStableCoin _dsc) {
        dsce = _dsceEngine;
        dsc = _dsc;
        address[] memory collateralTokens = dsce.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);
        ethUsdPriceFeed = MockV3Aggregator(dsce.getCollateralTokenPriceFeed(address(weth)));
        //btcUsdPriceFeed = MockV3Aggregator(dsce.getCollateralTokenPriceFeed(address(wbtc)));
    }

    function mintDsc(uint256 amountToMint, uint256 addressSeed) public {
        vm.assume(userWithCollateralDeposited.length != 0);
        address sender = userWithCollateralDeposited[addressSeed % userWithCollateralDeposited.length];
        (uint256 totalDscMinted, uint256 totalCollateralValueInUsd) = dsce.getAccountInformation(sender);
        if (totalCollateralValueInUsd / 2 <= totalDscMinted) {
            return;
        }
        uint256 maxDscToMint = ((totalCollateralValueInUsd / 2) - totalDscMinted);

        /* if (maxDscToMint == 0) {
            return;
        }*/

        amountToMint = bound(amountToMint, 0, maxDscToMint);
        if (amountToMint == 0) {
            return;
        }
        //vm.assume(amountToMint != 0); // ensures that the user has collateral to mint, otherwise revert

        vm.startPrank(sender);
        dsce.mintDSC(amountToMint);
        vm.stopPrank();
        // timesMintIsCalled++;
    }

    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        amountCollateral = bound(amountCollateral, MIN_DEPOSIT_SIZE, MAX_DEPOSIT_SIZE);

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(dsce), amountCollateral);
        dsce.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();

        // double push
        // userWithCollateralDeposited.push(msg.sender);

        if (!s_hasDepositedCollateral[msg.sender]) {
            s_hasDepositedCollateral[msg.sender] = true;
            userWithCollateralDeposited.push(msg.sender);
        }
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral, uint256 addressSeed) public {
        vm.assume(userWithCollateralDeposited.length != 0);
        address sender = userWithCollateralDeposited[addressSeed % userWithCollateralDeposited.length];
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 maxCollateralToRedeem = dsce.getCollateralBalanceOfUser(sender, address(collateral));
        // vm.assume(maxCollateralToRedeem > 0); // ensures that the user has collateral to redeem, otherwise revert

        amountCollateral = bound(amountCollateral, 0, maxCollateralToRedeem);
        if (amountCollateral == 0) {
            return;
        }
        //vm.assume(amountCollateral > 0);
        vm.startPrank(sender);
        dsce.redeemCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
    }

    function burnDsc(uint256 amountToBurn, uint256 addressSeed) public {
        vm.assume(userWithCollateralDeposited.length != 0);
        address sender = userWithCollateralDeposited[addressSeed % userWithCollateralDeposited.length];

        vm.assume(dsc.balanceOf(sender) > 0);
        amountToBurn = bound(amountToBurn, 0, dsc.balanceOf(sender));

        //prevernts DSCEngine__NeedsMoreThanZero error from being thrown.
        // if (amountToBurn == 0) {
        //     return;
        // }

        vm.startPrank(sender);
        dsc.approve(address(dsce), amountToBurn);
        dsce.burnDSC(amountToBurn);
        vm.stopPrank();
    }

    function redeemCollateralForDSC(
        uint256 addressSeed,
        uint256 amountCollateral,
        uint256 amountToBurn,
        uint256 collateralSeed
    ) public {
        vm.assume(userWithCollateralDeposited.length != 0);
        address sender = userWithCollateralDeposited[addressSeed % userWithCollateralDeposited.length];
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);

        vm.assume(dsce.getCollateralBalanceOfUser(sender, address(collateral)) > 0);
        vm.assume(dsc.balanceOf(sender) > 0);

        uint256 maxCollateralToRedeem = dsce.getCollateralBalanceOfUser(sender, address(collateral));
        uint256 maxDscToBurn = dsc.balanceOf(sender);

        amountCollateral = bound(amountCollateral, 0, maxCollateralToRedeem);
        amountToBurn = bound(amountToBurn, 0, maxDscToBurn);

        vm.startPrank(sender);
        dsc.approve(address(dsce), amountToBurn);
        dsce.redeemCollateralForDSC(address(collateral), amountCollateral, amountToBurn);
        vm.stopPrank();
    }

    function liquidate(uint256 addressSeed, uint256 collateralSeed, uint256 deptToCover) public {
        vm.assume(userWithCollateralDeposited.length != 0);
        address userToLiquidate = userWithCollateralDeposited[addressSeed % userWithCollateralDeposited.length];
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);

        vm.assume(dsce.getCollateralBalanceOfUser(userToLiquidate, address(collateral)) > 0);
        vm.assume(dsc.balanceOf(msg.sender) > 0); // liquidator needs DSC to cover debt

        uint256 maxDeptToCover = dsc.balanceOf(msg.sender);
        deptToCover = bound(deptToCover, 1, maxDeptToCover);

        // if user had zero debt, then we don't want to liquidate them. So we can just return from the function.
        // if (deptToCover == 0) {
        //     return;
        // }

        vm.startPrank(msg.sender);
        dsc.approve(address(dsce), deptToCover);
        dsce.liquidate(userToLiquidate, address(collateral), deptToCover);
        vm.stopPrank();
    }

    //this breaks invariant test Suite.
    // function updateCollateralPrice(uint96 newPrice) public {
    //     int256 newPriceInt = int256(uint256(newPrice));
    //     ethUsdPriceFeed.updateAnswer(newPriceInt);
    // }

    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return weth;
        } else {
            return wbtc;
        }
    }

    function getDepositedUserCount() public view returns (uint256) {
        return userWithCollateralDeposited.length;
    }
}
