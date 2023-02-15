// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { IRentalAuction } from "./IRentalAuction.sol";

interface IRentalAuctionControllerObserver {
    function initialize(IRentalAuction rentalAuction, address owner, bytes calldata auxData) external;
    function onRenterChanged(address newRenter) external;

    // function tokenURI() external view returns (string memory);
    // function tokenName() external view returns (string memory);

    function startAuction() external;
    function stopAuction() external;

    function underlyingTokenContract() external view returns (address);
    function underlyingTokenID() external view returns (uint256);

    // function rentalAuction() external view returns (address);

    // todo: only 2 first funcs in here
}