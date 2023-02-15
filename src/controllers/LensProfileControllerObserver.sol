// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { ILensHub } from "../interfaces/ILensHub.sol";
import { LensDataTypes } from "../libraries/LensDataTypes.sol";

import { ControllerObserver } from "./ControllerObserver.sol";

contract LensProfileControllerObserver is ControllerObserver {    
    function _onRenterChanged(address) internal pure override {}

    function post(LensDataTypes.PostData calldata postData) external {
        if (msg.sender != rentalAuction.currentRenter()) revert Unauthorized();
        ILensHub(address(tokenContract)).post(postData);
    }
}