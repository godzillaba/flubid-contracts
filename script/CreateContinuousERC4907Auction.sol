// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import { ContinuousRentalAuctionFactory } from "../src/factories/ContinuousRentalAuctionFactory.sol";
import { ISuperfluid, ISuperToken } from "superfluid-finance/contracts/interfaces/superfluid/ISuperfluid.sol";


contract CreateContinuousLensAuction is Script {
    ContinuousRentalAuctionFactory factory = ContinuousRentalAuctionFactory(0x232BbC02b5FF8bFc94CB9b7163F58f8bF82E6AfD);

    address erc4907ControllerObserverImpl = 0xbDb5baeb476AeE7904441039e1F712d7DDD88A56;
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
