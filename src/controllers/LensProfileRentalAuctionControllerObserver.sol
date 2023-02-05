// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { OwnableUpgradeable } from "openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";

import { LensHub } from "lens-protocol/core/LensHub.sol";
import { DataTypes } from "lens-protocol/libraries/DataTypes.sol";

import { IRentalAuctionControllerObserver } from "../interfaces/IRentalAuctionControllerObserver.sol";
import { IRentalAuction } from "../interfaces/IRentalAuction.sol";

contract LensProfileRentalAuctionControllerObserver is IRentalAuctionControllerObserver, OwnableUpgradeable {
    LensHub constant lensHub = LensHub(0x60Ae865ee4C725cd04353b5AAb364553f56ceF82);
    uint256 public tokenId;

    IRentalAuction public rentalAuction; 

    event AuctionStopped();
    event AuctionStarted();

    error Unauthorized();

    error TokenNotOwned();

    function initialize(IRentalAuction _rentalAuction, bytes calldata extraArgs) public initializer {
        __Ownable_init();

        rentalAuction = _rentalAuction;
        (tokenId) = abi.decode(extraArgs, (uint256));

        _rentalAuction.pause(); // pause the auction because we need to get the nft in here first
    }

    modifier onlyRentalAuction {
        if (msg.sender != address(rentalAuction)) revert Unauthorized();
        _;
    }

    modifier onlyRenter {
        if (msg.sender != rentalAuction.currentRenter()) revert Unauthorized();
        _;
    }

    function onRenterChanged(address newRenter) external pure {}

    function stopAuction() external onlyOwner {
        // pause auction
        rentalAuction.pause();

        // send back the nft
        lensHub.transferFrom(address(this), owner(), tokenId);

        emit AuctionStopped();
    }

    function startAuction() external onlyOwner {
        // unpause auction
        rentalAuction.unpause();

        // pull in the nft
        lensHub.transferFrom(owner(), address(this), tokenId);

        emit AuctionStarted();
    }

    function post(DataTypes.PostData calldata postData) external onlyRenter {
        lensHub.post(postData);
    }
}