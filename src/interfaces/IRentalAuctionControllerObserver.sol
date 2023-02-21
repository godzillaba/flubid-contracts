// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { IRentalAuction } from "./IRentalAuction.sol";

interface IRentalAuctionControllerObserver {
    /// @notice Initializes the controller contract
    /// @param rentalAuction The rental auction contract that this controller is attached to
    /// @param owner The owner of this controller contract
    /// @param extraArgs ABI encoded additional arguments for the controller
    function initialize(IRentalAuction rentalAuction, address owner, bytes calldata extraArgs) external;

    /// @notice Called by the rental auction contract when the renter has changed
    /// @dev THIS FUNCTION MUST NOT REVERT
    /// @param newRenter The new renter
    function onRenterChanged(address newRenter) external;
}