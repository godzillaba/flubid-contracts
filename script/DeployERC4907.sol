// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import { ERC4907 } from "../test/mocks/ERC4907.sol";

contract DeployERC4907 is Script {
    string baseURI = "ipfs://QmeGBX2mFZBu3JrqftnEiW5gaWaG7MHe6brsaokCWLUdzS";
    string name = "SuperGame 7: Double XP Token";
    string symbol = "SG7-2XP";

    function setUp() public {}

    function run() public {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        
        vm.startBroadcast(privateKey);

        ERC4907 token = new ERC4907(name, symbol, baseURI);

        token.mint(1);

        console.log(address(token));

        vm.stopBroadcast();
    }
}