// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import {IRentalAuctionControllerObserver} from "../src/interfaces/IRentalAuctionControllerObserver.sol";
import {IERC721} from "openzeppelin-contracts/interfaces/IERC721.sol";

contract StartERC4907RentalAuction is Script {
    IRentalAuctionControllerObserver controller = IRentalAuctionControllerObserver(0xb9D8a5dbfb87dE415963938636B5Bb5B984B29E2);
    IERC721 nft = IERC721(0xe1F6BD28cdff9e1bFB8CaC69664d9519F858793B);

    function setUp() external {}

    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        
        vm.startBroadcast(privateKey);

        nft.approve(address(controller), 1);
        controller.startAuction();

        vm.stopBroadcast();
    }
}