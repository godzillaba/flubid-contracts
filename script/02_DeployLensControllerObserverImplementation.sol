// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import { ContinuousRentalAuctionFactory } from "../src/factories/ContinuousRentalAuctionFactory.sol";
import { ISuperfluid, ISuperToken } from "superfluid-finance/contracts/interfaces/superfluid/ISuperfluid.sol";

import { ILensHub } from "../src/interfaces/ILensHub.sol";

import { LensProfileControllerObserver } from "../src/controllers/LensProfileControllerObserver.sol";

contract DeployLensControllerObserverImplementation is Script {
    function setUp() public {}

    function run() public {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        
        vm.startBroadcast(privateKey);

        LensProfileControllerObserver controllerImpl = new LensProfileControllerObserver{salt: bytes32(uint256(100))}();

        console.log("Lens controller implementation deployed to:", address(controllerImpl));
        
        vm.stopBroadcast();
    }
}
