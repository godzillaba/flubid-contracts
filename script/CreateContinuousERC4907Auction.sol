// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import { ContinuousRentalAuctionFactory } from "../src/factories/ContinuousRentalAuctionFactory.sol";
import { ISuperfluid, ISuperToken } from "superfluid-finance/contracts/interfaces/superfluid/ISuperfluid.sol";


contract CreateContinuousLensAuction is Script {
    ContinuousRentalAuctionFactory factory = ContinuousRentalAuctionFactory(0x7333098d87a4823c821f9BA7F6e200F9001B3BA7);

    address erc4907ControllerObserverImpl = 0x8a92528cCfbdFB6cCfa982e936E844a56D9D47ba;
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
            _acceptedToken: maticx,
            _controllerObserverImplementation: erc4907ControllerObserverImpl,
            _beneficiary: account,
            _minimumBidFactorWad: uint96(minimumBidFactorWad),
            _reserveRate: reserveRate,
            _controllerObserverExtraArgs: abi.encode(erc4907, tokenId)
        });

        console.log("Auction deployed to:", auction);
        console.log("Controller deployed to:", controller);
        
        vm.stopBroadcast();
    }
}
