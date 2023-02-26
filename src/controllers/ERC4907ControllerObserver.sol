// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { IERC4907 } from "../interfaces/IERC4907.sol";
import { ERC721ControllerObserver } from "./ERC721ControllerObserver.sol";

/// @title ERC4907ControllerObserver
/// @notice Rental auction controller for ERC4907 tokens
contract ERC4907ControllerObserver is ERC721ControllerObserver {
    /// @notice Handle renter changed by setting the user of the ERC4907 token
    /// @dev The expiration time is set to the maximum value of uint64
    /// @param newRenter The new renter to set as the user of the ERC4907 token
    function _onRenterChanged(address, address newRenter) internal override {
        IERC4907(address(tokenContract)).setUser(tokenId, newRenter, type(uint64).max);
    }
}