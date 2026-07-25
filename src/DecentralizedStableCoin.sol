// SPDX license-Identifier: MIT
pragma solidity ^0.8.19;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/*
 *@title DecentralizedStableCoin
 *@author Amer k.
 *Collateral: ETH and BTC
 *Minting: Algorithmic
 *Relative Stability: Pegged to USD
 *
 * This is the contract meant to be governed by the DSCEngine. This contract is just the ERC20
 implementation of our StableCoin System.
 * SafeERC20 is used to interact with the collateral tokens, but not for the minting and burning of the stablecoin itself, since we have control over that contract and can ensure that it is used correctly.
 */

contract DecentralizedStableCoin is ERC20Burnable, Ownable {
    error DecentralizedStableCoin__MustBeGreaterThanZero();
    error DecentralizedStableCoin__BurnAmountExceedsBalance();
    error DecentralizedStableCoin__MintToZeroAddress();

    constructor(address _initialOwner) ERC20("DecentralizedStableCoin", "DSC") Ownable(_initialOwner) {}

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if (_amount <= 0) {
            revert DecentralizedStableCoin__MustBeGreaterThanZero();
        }
        if (balance < _amount) {
            revert DecentralizedStableCoin__BurnAmountExceedsBalance();
        }
        super.burn(_amount);
    }

    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        if (_to == address(0)) {
            revert DecentralizedStableCoin__MintToZeroAddress();
        }
        if (_amount <= 0) {
            revert DecentralizedStableCoin__MustBeGreaterThanZero();
        }
        _mint(_to, _amount);
        return true;
    }
}
