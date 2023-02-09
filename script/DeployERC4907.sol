// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import { ERC4907Metadata } from "../src/erc4907/ERC4907Metadata.sol";

contract DeployERC4907 is Script {
    string baseURI = "ipfs://QmeGBX2mFZBu3JrqftnEiW5gaWaG7MHe6brsaokCWLUdzS";
    string name = "SuperGame 7: Double XP Token";
    string symbol = "SG7-2XP";

    function setUp() public {}

    function run() public {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        
        vm.startBroadcast(privateKey);

        ERC4907Metadata token = new ERC4907Metadata(name, symbol, baseURI);

        token.mint(1);

        console.log(address(token));

        vm.stopBroadcast();
    }
}