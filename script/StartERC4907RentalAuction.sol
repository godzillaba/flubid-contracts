// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import {ControllerObserver} from "../src/controllers/ControllerObserver.sol";
import {ERC4907Metadata} from "../src/erc4907/ERC4907Metadata.sol";

contract StartERC4907RentalAuction is Script {
    ControllerObserver controller = ControllerObserver(0xe04b15C246F9102e9198d6a255dD614d2Ac03f46);
    ERC4907Metadata nft = ERC4907Metadata(0xe1F6BD28cdff9e1bFB8CaC69664d9519F858793B);

    function setUp() external {}

    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        
        vm.startBroadcast(privateKey);

        nft.mint(3);

        nft.approve(address(controller), 3);
        controller.startAuction();

        vm.stopBroadcast();
    }
}