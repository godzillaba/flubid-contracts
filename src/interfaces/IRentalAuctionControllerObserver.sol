// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { IRentalAuction } from "./IRentalAuction.sol";

interface IRentalAuctionControllerObserver {
    function initialize(IRentalAuction rentalAuction, bytes calldata auxData) external;
    function onRenterChanged(address newRenter) external; // todo: maybe call this onRenterChanged?
}