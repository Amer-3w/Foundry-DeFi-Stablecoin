// SPDXL-liscense-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine engine;
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address wbtc;
    uint256 deployerKey;
    address public USER = makeAddr("user");
    address public LIQUIDATOR = makeAddr("liquidator");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant LIQUIDATOR_AMOUNT = 25 ether;
    uint256 public constant AMOUNT_TO_MINT_LIQUIDATOR = 10000e18;
    uint256 public constant AMOUNT_TO_MINT = 10000e18;
    uint256 public constant AMOUNT_TO_BREAK_HEALTH_FACTOR = 15000e18;
    uint256 public constant AMOUNT_TO_BREAK_HEALTH_FACTOR_ETH = 5 ether;
    uint256 public constant AMOUNT_TO_BURN = 10000e18; // equals all the minted DSC
    uint256 public constant AMOUNT_TO_REDEEM = 5 ether; // equals 50% of the collateral

    modifier depositCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    modifier DepositAndMintLiquidator() {
        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(engine), LIQUIDATOR_AMOUNT);
        engine.depositCollateral(weth, LIQUIDATOR_AMOUNT);
        engine.mintDSC(AMOUNT_TO_MINT_LIQUIDATOR);
        vm.stopPrank();
        _;
    }

    function setUp() public {
        deployer = new DeployDSC();
        (engine, dsc, config) = deployer.run();
        (weth, wbtc, ethUsdPriceFeed, btcUsdPriceFeed, deployerKey) = config.activeNetworkConfig();
        ERC20Mock(weth).mint(USER, AMOUNT_COLLATERAL);
        ERC20Mock(weth).mint(LIQUIDATOR, LIQUIDATOR_AMOUNT);
    }

    ////////// constructor feed tests //////////
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertIfTokenLengthDoesNotMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);
        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeTheSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    ////////// price feed tests //////////

    function testGetUsdValue() public view {
        uint256 ethAmount = 10e18;
        uint256 expectedUsdValue = 20000e18; // Assuming the price feed returns $2000 per ETH;
        uint256 actualUsdValue = engine.getUsdValue(weth, ethAmount);
        assertEq(expectedUsdValue, actualUsdValue);
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 100 ether;
        uint256 expectedWeth = 0.05 ether; // Assuming the price feed returns $2000 per ETH, $100 worth of ETH would be 0.05 ETH
        uint256 actualWeth = engine.getTokenAmountFromUsdValue(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
    }
    ////////// deposit collateral tests //////////

    function testRevertIfCollateralIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertWithUnApprovedCollateral() public {
        ERC20Mock notAllowedToken = new ERC20Mock();
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__TokenNotAllowed.selector);
        engine.depositCollateral(address(notAllowedToken), 1);
        vm.stopPrank();
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositCollateral {
        (uint256 totalDscMinted, uint256 totalCollateralValueInUsd) = engine.getAccountInformation(USER);
        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositAmmount = engine.getTokenAmountFromUsdValue(weth, totalCollateralValueInUsd);
        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmmount);
    }

    function testCanMintAfterDepositingCollateral() public depositCollateral {
        uint256 expectedTotalDscMinted = AMOUNT_TO_MINT;
        vm.startPrank(USER);
        engine.mintDSC(AMOUNT_TO_MINT);
        vm.stopPrank();
        assertEq(dsc.balanceOf(USER), expectedTotalDscMinted);
    }

    function testRevertIfMintedDscExceedsHealthFactor() public depositCollateral {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorIsBroken.selector);
        engine.mintDSC(AMOUNT_TO_BREAK_HEALTH_FACTOR);
        vm.stopPrank();
    }

    function testDepositCollateralAndMintDcs() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralAndMintDSC(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        vm.stopPrank();
        assertEq(dsc.balanceOf(USER), AMOUNT_TO_MINT);
    }

    function testCanBurnDsc() public depositCollateral {
        vm.startPrank(USER);
        engine.mintDSC(AMOUNT_TO_MINT);
        dsc.approve(address(engine), AMOUNT_TO_BURN);
        engine.burnDSC(AMOUNT_TO_BURN);
        vm.stopPrank();
        assertEq(dsc.balanceOf(USER), 0);
    }

    function testRedeemCollateral() public depositCollateral {
        vm.startPrank(USER);
        engine.redeemCollateral(weth, AMOUNT_TO_REDEEM);
        vm.stopPrank();
    }

    function testRevertIfRedeemingCollateralBreaksHealthFactor() public depositCollateral {
        vm.startPrank(USER);
        engine.mintDSC(AMOUNT_TO_MINT);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorIsBroken.selector);
        engine.redeemCollateral(weth, AMOUNT_TO_BREAK_HEALTH_FACTOR_ETH);
        vm.stopPrank();
    }

    function testRedeemCollateralForDsc() public depositCollateral {
        vm.startPrank(USER);
        engine.mintDSC(AMOUNT_TO_MINT);
        dsc.approve(address(engine), AMOUNT_TO_BURN);
        engine.redeemCollateralForDSC(weth, AMOUNT_TO_REDEEM, AMOUNT_TO_BURN);
        vm.stopPrank();
        assertEq(dsc.balanceOf(USER), 0);
    }

    function testLiquidate() public DepositAndMintLiquidator {
        uint256 additionalCollateral = AMOUNT_COLLATERAL + 5 ether;
        ERC20Mock(weth).mint(USER, 5 ether);

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), additionalCollateral);
        engine.depositCollateral(weth, additionalCollateral);
        engine.mintDSC(AMOUNT_TO_MINT);
        vm.stopPrank();
        vm.mockCall(
            address(ethUsdPriceFeed),
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(0), int256(1000e8), uint256(0), uint256(0), uint80(0))
        );

        uint256 debtToCover = 10000e18; //debt is 10000e18;
        vm.startPrank(LIQUIDATOR);
        dsc.approve(address(engine), debtToCover);
        engine.liquidate(weth, USER, debtToCover);
        vm.stopPrank();
    }

    function testReverIfUserHealthInLiquidationIsAboveMinimum() public DepositAndMintLiquidator depositCollateral {
        vm.startPrank(USER);
        engine.mintDSC(AMOUNT_TO_MINT);
        vm.stopPrank();

        uint256 debtToCover = 10000e18; //debt is 10000e18;
        vm.startPrank(LIQUIDATOR);
        dsc.approve(address(engine), debtToCover);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorIsAboveMinimum.selector);
        engine.liquidate(weth, USER, debtToCover);
        vm.stopPrank();
    }

    function testRevertIfUserHealthFactorHasNotImprovedAfterLiquidation() public DepositAndMintLiquidator {
        uint256 additionalCollateral = AMOUNT_COLLATERAL + 5 ether;
        ERC20Mock(weth).mint(USER, 5 ether);

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), additionalCollateral);
        engine.depositCollateral(weth, additionalCollateral);
        engine.mintDSC(AMOUNT_TO_MINT);
        vm.stopPrank();

        vm.mockCall(
            address(ethUsdPriceFeed),
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(0), int256(1000e8), uint256(0), uint256(0), uint80(0))
        );

        uint256 debtToCover = 1e1; //debt is 10000e18;
        vm.startPrank(LIQUIDATOR);
        dsc.approve(address(engine), debtToCover);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorHasNotImproved.selector);
        engine.liquidate(weth, USER, debtToCover);
        vm.stopPrank();
    }

    function testLiquidatorReceivesCollateralAndBonus() public DepositAndMintLiquidator {
        uint256 additionalCollateral = AMOUNT_COLLATERAL + 5 ether;
        ERC20Mock(weth).mint(USER, 5 ether);
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), additionalCollateral);
        engine.depositCollateral(weth, additionalCollateral);
        engine.mintDSC(AMOUNT_TO_MINT);
        vm.stopPrank();

        vm.mockCall(
            address(ethUsdPriceFeed),
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(0), int256(1000e8), uint256(0), uint256(0), uint80(0))
        );

        uint256 debtToCover = 1000e18;
        uint256 expectedCollateralFromDebt = engine.getTokenAmountFromUsdValue(weth, debtToCover);
        uint256 expectedBonus = (expectedCollateralFromDebt * 10) / 100;
        uint256 expectedTotalCollateral = expectedCollateralFromDebt + expectedBonus;

        uint256 liquidatorWethBalanceBefore = ERC20Mock(weth).balanceOf(LIQUIDATOR);

        vm.startPrank(LIQUIDATOR);
        dsc.approve(address(engine), debtToCover);
        engine.liquidate(weth, USER, debtToCover);
        vm.stopPrank();

        uint256 liquidatorWethBalanceAfter = ERC20Mock(weth).balanceOf(LIQUIDATOR);
        assertEq(liquidatorWethBalanceAfter - liquidatorWethBalanceBefore, expectedTotalCollateral);
    }

    function testCollateralDepositedEventEmitted() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);

        vm.expectEmit(true, true, true, true);
        emit DSCEngine.collateralDeposited(USER, weth, AMOUNT_COLLATERAL);

        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }
}
