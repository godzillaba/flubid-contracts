// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { IRentalAuction } from "./IRentalAuction.sol";

interface IRentalAuctionControllerObserver {
    /// @notice Initializes the controller contract.
    /// @param _rentalAuction The rental auction contract that this controller is attached to
    /// @param _owner The owner of this controller contract
    /// @param _extraArgs ABI encoded additional arguments for the controller
    function initialize(IRentalAuction _rentalAuction, address _owner, bytes calldata _extraArgs) external;

    /// @notice Called by the rental auction contract when the renter has changed.
    /// @dev THIS FUNCTION MUST NOT REVERT IF CALLED BY THE RENTAL AUCTION CONTRACT
    /// @param newRenter The new renter
    function onRenterChanged(address newRenter) external;
}