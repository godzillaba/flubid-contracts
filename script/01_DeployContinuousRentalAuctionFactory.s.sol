// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import { ContinuousRentalAuctionFactory } from "../src/factories/ContinuousRentalAuctionFactory.sol";
import { ISuperfluid } from "superfluid-finance/contracts/interfaces/superfluid/ISuperfluid.sol";

contract DeployContinuousRentalAuctionFactory is Script {
    function setUp() public {}

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        address sfHost = vm.envAddress("GOERLI_SUPERFLUID_HOST");
        address sfCfa = vm.envAddress("GOERLI_SUPERFLUID_CFA");

        ContinuousRentalAuctionFactory factory = new ContinuousRentalAuctionFactory{salt: bytes32(uint256(1))}(sfHost, sfCfa);

        console.log("ContinuousRentalAuctionFactory deployed to:", address(factory));

        vm.stopBroadcast();
    }
}
