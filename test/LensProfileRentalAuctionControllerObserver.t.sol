// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

// import {ISuperfluid, SuperAppDefinitions, BatchOperation} from "superfluid-finance/contracts/interfaces/superfluid/ISuperfluid.sol";

import {ISuperToken} from "superfluid-finance/contracts/interfaces/superfluid/ISuperToken.sol";
// import {ISuperTokenFactory} from "superfluid-finance/contracts/interfaces/superfluid/ISuperTokenFactory.sol";
// import {IConstantFlowAgreementV1} from "superfluid-finance/contracts/interfaces/agreements/IConstantFlowAgreementV1.sol";

// import {TestToken} from "superfluid-finance/contracts/utils/TestToken.sol";

// import {
//     SuperfluidFrameworkDeployer,
//     TestGovernance,
//     Superfluid,
//     ConstantFlowAgreementV1,
//     InstantDistributionAgreementV1,
//     IDAv1Library,
//     CFAv1Library,
//     SuperTokenFactory
// } from "superfluid-finance/contracts/utils/SuperfluidFrameworkDeployer.sol";


import { SuperTokenV1Library } from "superfluid-finance/contracts/apps/SuperTokenV1Library.sol";

// import { IRentalAuctionControllerObserver } from "../src/interfaces/IRentalAuctionControllerObserver.sol";
import { IRentalAuction } from "../src/interfaces/IRentalAuction.sol";

import { LensProfileRentalAuctionControllerObserver } from "../src/controllers/LensProfileRentalAuctionControllerObserver.sol";

contract LensProfileRentalAuctionControllerObserverTest is Test, IRentalAuction {
    // SuperToken library setup
    using SuperTokenV1Library for ISuperToken;

    LensProfileRentalAuctionControllerObserver controller;

    function setUp() external {
        controller = new LensProfileRentalAuctionControllerObserver();
        controller.initialize(
            IRentalAuction(this),
            abi.encode(1)
        );
    }

    function pause() external override {}

    function unpause() external override {}

    function currentRenter() external override returns (address) {}

    function senderUserData(
        address sender
    ) external override returns (bytes memory) {}
}
