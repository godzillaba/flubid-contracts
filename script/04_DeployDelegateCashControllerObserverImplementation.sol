// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import { DelegateCashControllerObserver } from "../src/controllers/DelegateCashControllerObserver.sol";

contract DeployLensControllerObserverImplementation is Script {
    function setUp() public {}

    function run() public {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        
        vm.startBroadcast(privateKey);

        DelegateCashControllerObserver controllerImpl = new DelegateCashControllerObserver{salt: bytes32(uint256(100))}();

        console.log("DelegateCash controller implementation deployed to:", address(controllerImpl));
        
        vm.stopBroadcast();
    }
}
