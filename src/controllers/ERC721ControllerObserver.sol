// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Initializable } from "openzeppelin-contracts/proxy/utils/Initializable.sol";
import { IERC721 } from "openzeppelin-contracts/token/ERC721/IERC721.sol";

import { IRentalAuction } from "../interfaces/IRentalAuction.sol";
import { IRentalAuctionControllerObserver } from "../interfaces/IRentalAuctionControllerObserver.sol";

/// @title ERC721ControllerObserver
/// @notice This abstract contract is the basis of a controller that rents out an ERC721 token
/// @dev Any inheriting contract must implement the _onRenterChanged function
abstract contract ERC721ControllerObserver is Initializable, IRentalAuctionControllerObserver {
    /// @notice The ERC721 token contract
    IERC721 internal tokenContract;
    /// @notice The ERC721 token id
    uint256 internal tokenId;

    /// @notice The owner of this controller contract
    address public owner;

    /// @notice The rental auction contract that this controller is attached to
    IRentalAuction public rentalAuction;

    /// @notice Emitted when the auction is stopped
    event AuctionStopped();

    /// @notice Emitted when the auction is started
    event AuctionStarted();

    /// @notice Emitted when the owner of this contract is changed
    /// @param previousOwner The previous owner
    /// @param newOwner The new owner
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /// @notice Emitted when the ERC721 token is withdrawn
    event TokenWithdrawn();

    /// @notice Emitted when the auction notifies the controller that the renter has changed
    /// @param oldRenter The old renter
    /// @param newRenter The new renter
    event RenterChanged(address indexed oldRenter, address indexed newRenter);

    /// @notice Error indicating that the caller is not authorized. (some functions are only callable by the owner or the auction contract)
    error Unauthorized();
    /// @notice Error indicating that the auction is not paused. (the token can only be withdrawn when the auction is paused)
    error AuctionNotPausedOrJailed();

    /// @inheritdoc IRentalAuctionControllerObserver
    /// @param _extraArgs ABI encoded [tokenContract, tokenId]
    function initialize(IRentalAuction _rentalAuction, address _owner, bytes calldata _extraArgs) external virtual initializer {
        owner = _owner;
        rentalAuction = _rentalAuction;
        (tokenContract, tokenId) = abi.decode(_extraArgs, (IERC721, uint256));
    }

    modifier onlyRentalAuction {
        if (msg.sender != address(rentalAuction)) revert Unauthorized();
        _;
    }

    modifier onlyOwner {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    /// @notice Transfers ownership of this controller contract to a new owner.
    /// @dev Only callable by the owner.
    /// @param newOwner The new owner.
    function transferOwnership(address newOwner) external onlyOwner {
        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    /// @notice Withdraws the ERC721 token from this contract to the contract owner.
    /// @dev Only callable by the owner.
    /// Reverts if the auction is not paused.
    function withdrawToken() external onlyOwner {
        if (!(rentalAuction.paused() || rentalAuction.isJailed())) revert AuctionNotPausedOrJailed();
        tokenContract.transferFrom(address(this), msg.sender, tokenId);
        emit TokenWithdrawn();
    }

    /// @notice Stops the auction.
    /// @dev Only callable by the owner.
    /// Calls the pause function on the rental auction contract.
    function stopAuction() external onlyOwner {
        rentalAuction.pause();
        emit AuctionStopped();
    }

    /// @notice Starts the auction.
    /// @dev Only callable by the owner.
    /// If the ERC721 token is not owned by this contract, it will be pulled in (or the transaction will revert).
    /// Calls the unpause function on the rental auction contract.
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

    /// @return The address of the ERC721 token contract
    function underlyingTokenContract() external view returns (address) {
        return address(tokenContract);
    }

    /// @return The ERC721 token id
    function underlyingTokenID() external view returns (uint256) {
        return tokenId;
    }

    /// @notice Called by the rental auction contract when the renter has changed
    /// @dev Only callable by the rental auction contract.
    /// @param oldRenter The old renter
    /// @param newRenter The new renter
    function onRenterChanged(address oldRenter, address newRenter) external onlyRentalAuction {
        _onRenterChanged(oldRenter, newRenter);
        emit RenterChanged(oldRenter, newRenter);
    }

    /// @notice Overridden by inheriting contracts to handle renter changes
    /// @dev THIS FUNCTION MUST NOT REVERT
    /// @param newRenter The new renter
    function _onRenterChanged(address oldRenter, address newRenter) internal virtual;
}