// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

interface IRentalAuction {
    function pause() external;
    function unpause() external;
    // function topStreamer() external returns (address);
    function currentRenter() external returns (address);
    function senderUserData(address sender) external returns (bytes memory);
}