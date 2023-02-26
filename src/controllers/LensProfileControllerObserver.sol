// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { ILensHub } from "../interfaces/ILensHub.sol";
import { ERC721ControllerObserver } from "./ERC721ControllerObserver.sol";

/// @title LensProfileControllerObserver
/// @notice Rental auction controller for Lens Profile tokens
contract LensProfileControllerObserver is ERC721ControllerObserver {  
    /// @notice Do nothing on renter changed  
    function _onRenterChanged(address, address) internal pure override {}

    /// @notice Post to the Lens Hub
    /// @dev Only callable by the current renter reported by the rental auction contract
    /// @param postData The data to post
    function post(ILensHub.PostData calldata postData) external {
        if (msg.sender != rentalAuction.currentRenter()) revert Unauthorized();
        ILensHub(address(tokenContract)).post(postData);
    }
}