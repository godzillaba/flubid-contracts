// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { IRentalAuction } from "./IRentalAuction.sol";

interface IRentalAuctionControllerObserver {
    function initialize(IRentalAuction rentalAuction, bytes calldata auxData) external;
    function onWinnerChanged(address newWinner) external; // todo: maybe call this onRenterChanged?
}