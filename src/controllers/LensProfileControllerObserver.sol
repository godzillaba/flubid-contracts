// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { ILensHub } from "../interfaces/ILensHub.sol";
import { LensDataTypes } from "../libraries/LensDataTypes.sol";

import { ERC721ControllerObserver } from "./ERC721ControllerObserver.sol";

contract LensProfileControllerObserver is ERC721ControllerObserver {    
    function _onRenterChanged(address) internal pure override {}

    function post(LensDataTypes.PostData calldata postData) external {
        if (msg.sender != rentalAuction.currentRenter()) revert Unauthorized();
        ILensHub(address(tokenContract)).post(postData);
    }
}