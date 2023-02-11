// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import { EnglishRentalAuctionFactory } from "../src/factories/EnglishRentalAuctionFactory.sol";
import { ISuperfluid } from "superfluid-finance/contracts/interfaces/superfluid/ISuperfluid.sol";

contract DeployEnglishRentalAuctionFactory is Script {
    function setUp() public {}

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        address sfHost = vm.envAddress("MUMBAI_SUPERFLUID_HOST");
        address sfCfa = vm.envAddress("MUMBAI_SUPERFLUID_CFA");

        EnglishRentalAuctionFactory factory = new EnglishRentalAuctionFactory{salt: bytes32(uint256(1))}(sfHost, sfCfa);

        console.log("EnglishRentalAuctionFactory deployed to:", address(factory));

        vm.stopBroadcast();
    }
}
