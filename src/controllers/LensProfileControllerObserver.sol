// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { OwnableUpgradeable } from "openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";

import { ILensHub } from "../interfaces/ILensHub.sol";
import { LensDataTypes } from "../libraries/LensDataTypes.sol";

import { IRentalAuctionControllerObserver } from "../interfaces/IRentalAuctionControllerObserver.sol";
import { IRentalAuction } from "../interfaces/IRentalAuction.sol";

contract LensProfileControllerObserver is IRentalAuctionControllerObserver, OwnableUpgradeable {
    ILensHub constant lensHub = ILensHub(0x60Ae865ee4C725cd04353b5AAb364553f56ceF82);
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

    function post(LensDataTypes.PostData calldata postData) external onlyRenter {
        lensHub.post(postData);
    }

    function tokenURI() external view returns (string memory) {
        return lensHub.tokenURI(tokenId);
    }

    function tokenName() external view returns (string memory) {
        return lensHub.name();
    }
}