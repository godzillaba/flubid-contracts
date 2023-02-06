// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import { IBaseRegistrar } from "ens-contracts/ethregistrar/IBaseRegistrar.sol";

import { IRentalAuctionControllerObserver } from "../interfaces/IRentalAuctionControllerObserver.sol";
import { IRentalAuction } from "../interfaces/IRentalAuction.sol";
// vitalik 0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045
// ens 0x57f1887a8BF19b14fC0dF6Fd9B2acc9Af147eA85

contract ENSControllerObserver is IRentalAuctionControllerObserver, Initializable {
    IBaseRegistrar constant ensRegistrar = IBaseRegistrar(0x57f1887a8BF19b14fC0dF6Fd9B2acc9Af147eA85);

    IRentalAuction rentalAuction;

    uint256 ensTokenId;

    address owner;

    error Unauthorized();

    error ENSNameNotOwned();

    function initialize(IRentalAuction _rentalAuction, bytes calldata extraArgs) external initializer {
        rentalAuction = _rentalAuction;
        (ensTokenId, owner) = abi.decode(extraArgs, (uint256, address));
    }

    modifier onlyRentalAuction {
        if (msg.sender != address(rentalAuction)) revert Unauthorized();
        _;
    }

    modifier onlyOwner {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    function _setENSNameController(address controller) private {
        // reclaim will set the controller
        ensRegistrar.reclaim(ensTokenId, controller);
    }

    function _transferENSName(address to) private {
        ensRegistrar.transferFrom(address(this), to, ensTokenId);
    }

    function onRenterChanged(address newRenter) external onlyRentalAuction {
        if (ensRegistrar.ownerOf(ensTokenId) != address(this)) revert ENSNameNotOwned();
        _setENSNameController(newRenter);
    }

    // TODO: isActive or something like that. It lets the auction contract know if it can accept bids or whatever else.

    function stopAuction() external onlyOwner {
        // pause auction
        rentalAuction.pause();
        
        // set controller
        _setENSNameController(owner);

        // transfer NFT out
        _transferENSName(owner);
    }

    function startAuction() external onlyOwner {
        // make sure we have the NFT
        if (ensRegistrar.ownerOf(ensTokenId) != address(this)) revert ENSNameNotOwned();

        // unpause auction
        rentalAuction.unpause();

        // set controller to current top bidder if it isn't 0x00
        address topStreamer = rentalAuction.currentRenter();
        if (topStreamer != address(0)) {
            _setENSNameController(topStreamer);
        }
    }
}