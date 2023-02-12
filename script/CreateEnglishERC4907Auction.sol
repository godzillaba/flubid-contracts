// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import { EnglishRentalAuctionFactory } from "../src/factories/EnglishRentalAuctionFactory.sol";
import { ISuperfluid, ISuperToken } from "superfluid-finance/contracts/interfaces/superfluid/ISuperfluid.sol";


contract CreateEnglishERC4907Auction is Script {
    EnglishRentalAuctionFactory constant factory = EnglishRentalAuctionFactory(0x9116FF8B1b18b65F1d5A711c174C40089109B6a4);

    address constant erc4907ControllerObserverImpl = 0xbDb5baeb476AeE7904441039e1F712d7DDD88A56;
    address constant erc4907 = 0xe1F6BD28cdff9e1bFB8CaC69664d9519F858793B;

    uint96 constant minimumBidFactorWad = 1.05 ether;
    int96 constant reserveRate = 10;

    uint64 constant minRentalDuration = 10 minutes;
    uint64 constant maxRentalDuration = 1 days;
    uint64 constant biddingPhaseDuration = 1 hours;
    uint64 constant biddingPhaseExtensionDuration = 15 minutes;

    ISuperToken maticx = ISuperToken(0x96B82B65ACF7072eFEb00502F45757F254c2a0D4);

    bytes createCalldata = abi.encodeWithSelector(
        factory.create.selector,
        CreateParams(
            maticx, 
            erc4907ControllerObserverImpl, 
            vm.addr(vm.envUint("PRIVATE_KEY")),
            minimumBidFactorWad,
            reserveRate,
            minRentalDuration,
            maxRentalDuration,
            biddingPhaseDuration,
            biddingPhaseExtensionDuration,
            abi.encode(erc4907, vm.envUint("TOKEN_ID"))
        )
        // ""
    );

    struct CreateParams {
        ISuperToken acceptedToken;
        address controllerObserverImplementation;
        address beneficiary;
        uint96 minimumBidFactorWad;
        int96 reserveRate;
        uint64 minRentalDuration;
        uint64 maxRentalDuration;
        uint64 biddingPhaseDuration;
        uint64 biddingPhaseExtensionDuration;
        bytes controllerObserverExtraArgs;
    }


    function setUp() public {}

    function run() public {
        // uint256 tokenId = vm.envUint("TOKEN_ID");
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        // address account = vm.addr(privateKey);
        
        vm.startBroadcast(privateKey);

        (bool success, bytes memory data) = address(factory).call(createCalldata);
        
        require(success, "Create failed");

        (address auction, address controller) = abi.decode(data, (address,address));

        console.log("Auction deployed to:", auction);
        console.log("Controller deployed to:", controller);
        
        vm.stopBroadcast();
    }
}
