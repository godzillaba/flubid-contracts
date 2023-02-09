// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { LensDataTypes } from "../libraries/LensDataTypes.sol";

interface ILensHub {
    function post(LensDataTypes.PostData calldata vars) external returns (uint256);
    function transferFrom(address from, address to, uint256 tokenId) external;
    function approve(address to, uint256 tokenId) external;
    function createProfile(LensDataTypes.CreateProfileData calldata vars) external returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
    function tokenURI(uint256 tokenId) external view returns (string memory);
    function name() external view returns (string memory);
}