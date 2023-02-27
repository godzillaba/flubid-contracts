// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { IERC4907 } from "../interfaces/IERC4907.sol";
import { IDelegationRegistry } from "../interfaces/IDelegationRegistry.sol";
import { ERC721ControllerObserver } from "./ERC721ControllerObserver.sol";

/// @title DelegateCashControllerObserver
/// @notice Rental auction controller delegates the ERC721 token to the renter using delegate.cash
contract DelegateCashControllerObserver is ERC721ControllerObserver {
    /// @notice The delegate.cash contract
    IDelegationRegistry public constant delegateCash = IDelegationRegistry(0x00000000000076A84feF008CDAbe6409d2FE638B);

    /// @notice Handle renter changed by delegating the ERC721 token to the new renter
    /// @param oldRenter The old renter
    /// @param newRenter The new renter
    function _onRenterChanged(address oldRenter, address newRenter) internal override {
        // Revoke the old renter
        if (oldRenter != address(0)) {
            delegateCash.delegateForAll(oldRenter, false);
        }

        // Delegate the new renter
        if (newRenter != address(0)) {
            delegateCash.delegateForAll(newRenter, true);
        }
    }
}