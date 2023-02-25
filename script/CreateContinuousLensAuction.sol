// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import { ContinuousRentalAuctionFactory } from "../src/factories/ContinuousRentalAuctionFactory.sol";
import { ISuperfluid, ISuperToken } from "superfluid-finance/contracts/interfaces/superfluid/ISuperfluid.sol";

import { ILensHub } from "../src/interfaces/ILensHub.sol";

contract CreateContinuousLensAuction is Script {
    ContinuousRentalAuctionFactory factory = ContinuousRentalAuctionFactory(0x232BbC02b5FF8bFc94CB9b7163F58f8bF82E6AfD);
    ILensHub lensHub = ILensHub(0x60Ae865ee4C725cd04353b5AAb364553f56ceF82);

    address lensControllerObserverImpl = 0x11bc64F68fBe2899b581f7DEEf204d49BA445957;

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
            controllerObserverImplementation: lensControllerObserverImpl,
            minimumBidFactorWad: uint96(minimumBidFactorWad),
            reserveRate: reserveRate,
            controllerObserverExtraArgs: abi.encode(tokenId)
        });

        console.log("Auction deployed to:", auction);
        console.log("Controller deployed to:", controller);
        
        vm.stopBroadcast();
    }
}
