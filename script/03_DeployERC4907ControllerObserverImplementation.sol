// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import { ERC4907ControllerObserver } from "../src/controllers/ERC4907ControllerObserver.sol";

contract DeployLensControllerObserverImplementation is Script {
    function setUp() public {}

    function run() public {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        
        vm.startBroadcast(privateKey);

        ERC4907ControllerObserver controllerImpl = new ERC4907ControllerObserver{salt: bytes32(uint256(1))}();

        console.log("ERC4907 controller implementation deployed to:", address(controllerImpl));
        
        vm.stopBroadcast();
    }
}
