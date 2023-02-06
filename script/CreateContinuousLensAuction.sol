// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import { ContinuousRentalAuctionFactory } from "../src/factories/ContinuousRentalAuctionFactory.sol";
import { ISuperfluid, ISuperToken } from "superfluid-finance/contracts/interfaces/superfluid/ISuperfluid.sol";

import { ILensHub } from "../src/interfaces/ILensHub.sol";

contract CreateContinuousLensAuction is Script {
    ContinuousRentalAuctionFactory factory = ContinuousRentalAuctionFactory(0x70748EFAff42d57b45BAd846160de2B23285Cf29);
    ILensHub constant lensHub = ILensHub(0x60Ae865ee4C725cd04353b5AAb364553f56ceF82);

    uint256 minimumBidFactorWad = 1.05 ether;
    int96 reserveRate = 10;

    ISuperToken maticx = ISuperToken(0x96B82B65ACF7072eFEb00502F45757F254c2a0D4);


    function setUp() public {}

    function run() public {
        uint256 tokenId = vm.envUint("TOKEN_ID");
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address account = vm.addr(privateKey);
        
        vm.startBroadcast(privateKey);

        (address auction, address controller) = factory.createContinuousRentalAuctionWithController({
            _acceptedToken: maticx,
            _controllerObserverImplementation: 0x41664AdD9a2e371a788E84a8B5A1afAeB823e07B,
            _beneficiary: account,
            _minimumBidFactorWad: uint96(minimumBidFactorWad),
            _reserveRate: reserveRate,
            _controllerObserverExtraArgs: abi.encode(tokenId)
        });

        console.log("Auction deployed to:", auction);
        console.log("Controller deployed to:", controller);
        
        vm.stopBroadcast();
    }
}
