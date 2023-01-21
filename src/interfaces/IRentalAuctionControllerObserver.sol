// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

interface IRentalAuctionControllerObserver {
    function initialize(address rentalAuction, bytes calldata auxData) external;
    function onWinnerChanged(address newWinner) external;
}