// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import { IERC4907Metadata } from "../interfaces/IERC4907Metadata.sol";

import { IRentalAuctionControllerObserver } from "../interfaces/IRentalAuctionControllerObserver.sol";
import { IRentalAuction } from "../interfaces/IRentalAuction.sol";

contract ERC4907ControllerObserver is IRentalAuctionControllerObserver, Initializable {
    IERC4907Metadata public tokenContract;
    uint256 public tokenId;

    IRentalAuction public rentalAuction; 

    address public owner; // todo transferOwnership

    event AuctionStopped();
    event AuctionStarted();

    error Unauthorized();

    error TokenNotOwned();

    function initialize(IRentalAuction _rentalAuction, address _owner, bytes calldata extraArgs) public initializer {
        owner = _owner;
        rentalAuction = _rentalAuction;
        (tokenContract, tokenId) = abi.decode(extraArgs, (IERC4907Metadata, uint256));

        _rentalAuction.pause(); // pause the auction because we need to get the nft in here first
    }

    modifier onlyRentalAuction {
        if (msg.sender != address(rentalAuction)) revert Unauthorized();
        _;
    }

    modifier onlyOwner {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    function onRenterChanged(address newRenter) external onlyRentalAuction {
        tokenContract.setUser(tokenId, newRenter, type(uint64).max);
    }

    function stopAuction() external onlyOwner {
        // pause auction
        rentalAuction.pause();

        // send back the nft
        tokenContract.transferFrom(address(this), owner, tokenId);

        emit AuctionStopped();
    }

    function startAuction() external onlyOwner {
        // unpause auction
        rentalAuction.unpause();

        // pull in the nft
        tokenContract.transferFrom(owner, address(this), tokenId);

        emit AuctionStarted();
    }

    function underlyingTokenContract() external view returns (address) {
        return address(tokenContract);
    }
    function underlyingTokenID() external view returns (uint256) {
        return tokenId;
    }
}