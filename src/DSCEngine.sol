// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./library/OracleLib.sol";

using SafeERC20 for IERC20;
using SafeERC20 for DecentralizedStableCoin;

/*
 *@title DSCEngine
 *@author Amer k.
 *
 * The system is desgined to be as minimal as possible, and have the tokens maintain a 1 token == 1$ peg.
 *This StableCoin has the following properties:
 * - Exogonous collateral
 * - Dollar Pegged
 * - Algorithmically stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was only backed by WETH and WBTC.
 *
 * Our DCS system should always be "over-collateralized". At no point,  should the value of all the collateral <= the $backed value of all the DSC in circulation.
 *
 * @notice this contract is the core of the DSC system. it handles all the logic for minting and redeeming DSC, as well as depositing and withdrawing collateral.
 * @notice this contract is loosely based on DAI on the MakerDAO DSS (DAI) system.
 */
contract DSCEngine is ReentrancyGuard {
    /////////////// Errors /////////////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeTheSameLength();
    error DSCEngine__TokenNotAllowed();
    error DSCEngine__HealthFactorIsBroken();
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorIsAboveMinimum();
    error DSCEngine__HealthFactorHasNotImproved();
    error DSCEngine__InsufficientDscBalance();

    /////////////// types /////////////
    using OracleLib for AggregatorV3Interface;
    ///////////// state variables /////////////

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% collateralization ratio
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18; // less than 1 means they can get liquidated
    uint256 private constant LIQUIDATION_BONUS = 10; // 10% bonus for liquidators
    uint256 private constant HEALTH_FACTOR_PASS = type(uint256).max; // if you have no debt, then your health factor is infinite, which means you are very healthy.

    mapping(address token => address priceFeed) private s_priceFeeds;
    DecentralizedStableCoin private immutable i_dsc;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DscMinted;
    address[] private s_collateralTokens;

    ///////////// Events /////////////
    event collateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event collateralRedeemed(address indexed from, address indexed to, address indexed token, uint256 amount);

    ///////////// Modefiers /////////////

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier tokenAllowed(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__TokenNotAllowed();
        }
        _;
    }

    /////////////// Functions /////////////
    constructor(address[] memory tokenAddresses, address[] memory priceFeedsAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedsAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeTheSameLength();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedsAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /////////////// External Functions /////////////

    /*
    * @notice deposits collateral and mints DSC in one transaction
    * @param tokenCollateralAddress the address of the collateral token to deposit
    * @param amountCollateral the amount of collateral to deposit
    * @param amountDscToMint the amount of decentralized stablecoin to mint
    */
    function depositCollateralAndMintDSC(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDSC(amountDscToMint);
    }

    /*
     * @notice we are following CEI 
     * @param tokencCollateralAddress the address of the collateral token to desposit as collateral
     * @param amountCollateral the amount of collateral to desposit
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        tokenAllowed(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        // transfer the collateral from the user to the contract
        emit collateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        IERC20(tokenCollateralAddress).safeTransferFrom(msg.sender, address(this), amountCollateral);
    }
    /*
     * @notice redeem collateral and burn DSC in one transaction
     * @param tokenCollateralAddress the collateral address to redeem
     * @param amountCollateral the amount of collateral to redeem
     * @param amountDscToBurn the amount of DSC to burn
     */

    function redeemCollateralForDSC(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        burnDSC(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        //RedeemCollateral already checks for health factor.
    }

    //health factor should be above 1 after redeeming collateral, otherwise the transaction should revert.
    // the user should not be able to redeem more collateral than they have deposited.
    //DRY: Don't repeat yourself.
    //CEI: Checks, Effects, Interactions.
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }
    /*
     * @notice we are following CEI
     * @param amountDscToMint the amount of DSC to mint
     * @notice they must have more collateral value than the minimum threshold, otherwise the transaction will revert
     */

    function mintDSC(uint256 amountDscToMint) public moreThanZero(amountDscToMint) {
        s_DscMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool Minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!Minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDSC(uint256 amountDscToBurn) public moreThanZero(amountDscToBurn) {
        _burnDsc(msg.sender, msg.sender, amountDscToBurn);
        _revertIfHealthFactorIsBroken(msg.sender);
    }
    // if someone is under collateralized, then anyone can lequidate them and get paid in return.
    /*
    * @param collateral the ERC20 collateral address to lequidate.
    * @param user the address of the user who broke the health factor,which means they are below the MINIM_HEALTH_FACTOR and can get liquidated.
    * @param deptToCover the amount of DSC to burn to improve the user's health factor.
    * @notice You can partialy liquidate a user.
    * @notice You will get a liquidation bonus for taking the user's funds.
    * @notice This function working assumes the protocol will be roughly 200% overcollateralized in order for this to work.
    * @notice A known bug would be if the protocol were 100% or less collateralized, then we wont be able to incentivize the liquidators
    * Follows CEI: Checks, Effects, Interactions.
    */

    function liquidate(address collateral, address user, uint256 deptToCover)
        external
        moreThanZero(deptToCover)
        nonReentrant
    {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorIsAboveMinimum();
        }
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsdValue(collateral, deptToCover);
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralRedeemed = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(user, msg.sender, collateral, totalCollateralRedeemed);
        _burnDsc(user, msg.sender, deptToCover);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorHasNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /////////////// Private & Internal View Functions /////////////

    /*
    * @dev low-lever function,don't call unless the function calling it is checking for health factor being broken. 
    */

    function _burnDsc(address onBehalfOf, address dscFrom, uint256 amountDscToBurn) private {
        s_DscMinted[onBehalfOf] -= amountDscToBurn;
        i_dsc.safeTransferFrom(dscFrom, address(this), amountDscToBurn);

        i_dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit collateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        IERC20(tokenCollateralAddress).safeTransfer(to, amountCollateral);
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 totalCollateralValueInUsd)
    {
        totalDscMinted = s_DscMinted[user];
        totalCollateralValueInUsd = getAccountCollateralValue(user);
    }

    /*
     * 
     * Returns how close to liquidation a user is
     * if a user is below one ,then they can get liqidated
     */

    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 totalCollateralValueInUsd) = _getAccountInformation(user);
        if (totalDscMinted == 0) {
            return HEALTH_FACTOR_PASS;
        }
        uint256 collateralAdjustedForThreshold =
            (totalCollateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorIsBroken();
        }
    }

    /////////////// Public & External View Functions /////////////

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }
    // ETH/BTC are 8 decimals + additional feed precision (10 decimals).

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function getTokenAmountFromUsdValue(address tokenAddress, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[tokenAddress]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 totalCollateralValueInUsd)
    {
        (totalDscMinted, totalCollateralValueInUsd) = _getAccountInformation(user);
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256 amountDeposited) {
        return s_collateralDeposited[user][token];
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    function getMinimumHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }
}
