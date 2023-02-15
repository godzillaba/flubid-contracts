// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

// import { OwnableUpgradeable } from "openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";
import { Initializable } from "openzeppelin-contracts/proxy/utils/Initializable.sol";
import { IERC721Metadata } from "openzeppelin-contracts/token/ERC721/extensions/IERC721Metadata.sol";

import { IRentalAuction } from "../interfaces/IRentalAuction.sol";
import { IRentalAuctionControllerObserver } from "../interfaces/IRentalAuctionControllerObserver.sol";


abstract contract ControllerObserver is Initializable, IRentalAuctionControllerObserver {
    IERC721Metadata internal tokenContract;
    uint256 internal tokenId;

    address public owner;

    IRentalAuction public rentalAuction;

    event AuctionStopped();
    event AuctionStarted();
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event TokenWithdrawn();
    event RenterChanged(address indexed newRenter);

    error Unauthorized();
    error TokenNotOwned();
    error AuctionNotPaused();

    function initialize(IRentalAuction _rentalAuction, address _owner, bytes calldata extraArgs) external virtual initializer {
        owner = _owner;

        rentalAuction = _rentalAuction;
        (tokenContract, tokenId) = abi.decode(extraArgs, (IERC721Metadata, uint256));
    }

    modifier onlyRentalAuction {
        if (msg.sender != address(rentalAuction)) revert Unauthorized();
        _;
    }

    modifier onlyOwner {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    function withdrawToken() external onlyOwner {
        if (!rentalAuction.paused()) revert AuctionNotPaused();
        // send back the nft
        tokenContract.transferFrom(address(this), msg.sender, tokenId);

        emit TokenWithdrawn();
    }

    function stopAuction() external onlyOwner {
        // pause auction
        rentalAuction.pause();

        emit AuctionStopped();
    }

    function startAuction() external onlyOwner {
        // make sure we have the nft
        if (tokenContract.ownerOf(tokenId) != address(this)) {
            // pull in the nft
            tokenContract.transferFrom(owner, address(this), tokenId);
        }
        
        // unpause auction
        rentalAuction.unpause();

        emit AuctionStarted();
    }

    function underlyingTokenContract() external view returns (address) {
        return address(tokenContract);
    }
    function underlyingTokenID() external view returns (uint256) {
        return tokenId;
    }

    function onRenterChanged(address newRenter) external onlyRentalAuction {
        _onRenterChanged(newRenter);
        emit RenterChanged(newRenter);
    }

    function _onRenterChanged(address newRenter) internal virtual;
}