// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

// todo: define events in interfaces

interface IRentalAuction {
    function pause() external;
    function unpause() external;
    function paused() external view returns (bool);
    // function topStreamer() external returns (address);
    function currentRenter() external view returns (address);
}