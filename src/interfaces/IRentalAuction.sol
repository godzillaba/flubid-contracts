// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

interface IRentalAuction {
    function pause() external;
    function unpause() external;
    // function topStreamer() external returns (address);
    function currentRenter() external view returns (address);
    function senderUserData(address sender) external view returns (bytes memory);
}