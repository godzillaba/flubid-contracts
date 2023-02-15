// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { IERC4907Metadata } from "../interfaces/IERC4907Metadata.sol";
import { ERC721ControllerObserver } from "./ERC721ControllerObserver.sol";

contract ERC4907ControllerObserver is ERC721ControllerObserver {
    function _onRenterChanged(address newRenter) internal override {
        IERC4907Metadata(address(tokenContract)).setUser(tokenId, newRenter, type(uint64).max);
    }
}