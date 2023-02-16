// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import {ERC721ControllerObserver} from "../src/controllers/ERC721ControllerObserver.sol";
import {ERC4907Metadata} from "../src/erc4907/ERC4907Metadata.sol";

contract StartERC4907RentalAuction is Script {
    ERC721ControllerObserver controller = ERC721ControllerObserver(0x015d8EFE556225267Fd34b63638A9af223452468);
    ERC4907Metadata nft = ERC4907Metadata(0xe1F6BD28cdff9e1bFB8CaC69664d9519F858793B);

    function setUp() external {}

    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        uint256 tokenId = 5;
        
        vm.startBroadcast(privateKey);

        nft.mint(tokenId);

        nft.transferFrom(vm.addr(privateKey), address(controller), tokenId);
        controller.startAuction();

        vm.stopBroadcast();
    }
}