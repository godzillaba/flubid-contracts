// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { LensDataTypes } from "../libraries/LensDataTypes.sol";

interface ILensHub {
    function post(LensDataTypes.PostData calldata vars) external returns (uint256);
    function transferFrom(address from, address to, uint256 tokenId) external;
}