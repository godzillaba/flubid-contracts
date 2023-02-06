// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { OwnableUpgradeable } from "openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";

import { IERC4907 } from "../interfaces/IERC4907.sol";

import { IRentalAuctionControllerObserver } from "../interfaces/IRentalAuctionControllerObserver.sol";
import { IRentalAuction } from "../interfaces/IRentalAuction.sol";

contract ERC4907ControllerObserver is IRentalAuctionControllerObserver, OwnableUpgradeable {
    IERC4907 public tokenContract;
    uint256 public tokenId;

    IRentalAuction public rentalAuction; 

    event AuctionStopped();
    event AuctionStarted();

    error Unauthorized();

    error TokenNotOwned();

    function initialize(IRentalAuction _rentalAuction, bytes calldata extraArgs) public initializer {
        __Ownable_init();

        rentalAuction = _rentalAuction;
        (tokenContract, tokenId) = abi.decode(extraArgs, (IERC4907, uint256));

        _rentalAuction.pause(); // pause the auction because we need to get the nft in here first
    }

    modifier onlyRentalAuction {
        if (msg.sender != address(rentalAuction)) revert Unauthorized();
        _;
    }

    function onRenterChanged(address newRenter) external onlyRentalAuction {
        tokenContract.setUser(tokenId, newRenter, type(uint64).max);
    }

    function stopAuction() external onlyOwner {
        // pause auction
        rentalAuction.pause();

        // send back the nft
        tokenContract.transferFrom(address(this), owner(), tokenId);

        emit AuctionStopped();
    }

    function startAuction() external onlyOwner {
        // unpause auction
        rentalAuction.unpause();

        // pull in the nft
        tokenContract.transferFrom(owner(), address(this), tokenId);

        emit AuctionStarted();
    }
}