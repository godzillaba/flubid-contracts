// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

/// @title IRentalAuction
/// @notice Interface for RentalAuction contracts.
/// Controllers expect a RentalAuction contract to implement this interface.
interface IRentalAuction {
    /// @notice Pause the auction.
    function pause() external;

    /// @notice Unpause the auction.
    function unpause() external;

    /// @return Whether the auction is paused
    function paused() external view returns (bool);

    /// @return The current renter
    /// @dev Must return address(0) if the auction is paused.
    function currentRenter() external view returns (address);

    /// @return True if the auction is jailed.
    function isJailed() external view returns (bool);
}