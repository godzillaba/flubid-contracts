// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

interface IRentalAuction {
    function pause() external;
    function unpause() external;
    // function topStreamer() external returns (address);
    function currentWinner() external returns (address);
    function senderUserData(address sender) external returns (bytes memory);
}