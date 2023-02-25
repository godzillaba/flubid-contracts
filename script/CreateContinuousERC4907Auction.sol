// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import { ContinuousRentalAuctionFactory } from "../src/factories/ContinuousRentalAuctionFactory.sol";
import { ISuperfluid, ISuperToken } from "superfluid-finance/contracts/interfaces/superfluid/ISuperfluid.sol";


contract CreateContinuousERC4907Auction is Script {
    ContinuousRentalAuctionFactory factory = ContinuousRentalAuctionFactory(0x862E55E8ab6CD3cf914Cd889e22C142BD7faD15f);

    address erc4907ControllerObserverImpl = 0x786f9d6Cd7B63b7d69fB716E3b16eb9e54E6AE4D;
    address erc4907 = 0xe1F6BD28cdff9e1bFB8CaC69664d9519F858793B;

    uint256 minimumBidFactorWad = 1.05 ether;
    int96 reserveRate = 10;

    ISuperToken maticx = ISuperToken(0x96B82B65ACF7072eFEb00502F45757F254c2a0D4);


    function setUp() public {}

    function run() public {
        uint256 tokenId = vm.envUint("TOKEN_ID");
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address account = vm.addr(privateKey);
        
        vm.startBroadcast(privateKey);

        (address auction, address controller) = factory.create({
            acceptedToken: maticx,
            controllerObserverImplementation: erc4907ControllerObserverImpl,
            minimumBidFactorWad: uint96(minimumBidFactorWad),
            reserveRate: reserveRate,
            controllerObserverExtraArgs: abi.encode(erc4907, tokenId)
        });

        console.log("Auction deployed to:", auction);
        console.log("Controller deployed to:", controller);
        
        vm.stopBroadcast();
    }
}
