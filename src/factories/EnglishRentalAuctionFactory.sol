// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { ISuperfluid, ISuperApp, ISuperToken, SuperAppDefinitions } from "superfluid-finance/contracts/interfaces/superfluid/ISuperfluid.sol";
import { IConstantFlowAgreementV1 } from "superfluid-finance/contracts/interfaces/agreements/IConstantFlowAgreementV1.sol";
import { EnglishRentalAuction } from "../EnglishRentalAuction.sol";
import { IRentalAuction } from "../interfaces/IRentalAuction.sol";
import { IRentalAuctionControllerObserver } from "../interfaces/IRentalAuctionControllerObserver.sol";

contract EnglishRentalAuctionFactory {
    address immutable implementation;

    address immutable host;
    address immutable cfa;

    // we want to support after creation, revert on updating, after termination
    uint256 constant configWord = SuperAppDefinitions.APP_LEVEL_FINAL |
        SuperAppDefinitions.BEFORE_AGREEMENT_CREATED_NOOP |
        SuperAppDefinitions.AFTER_AGREEMENT_UPDATED_NOOP |
        SuperAppDefinitions.BEFORE_AGREEMENT_TERMINATED_NOOP;

    // stack too deep aaaaa
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

    event EnglishRentalAuctionDeployed(
        address indexed auctionAddress, 
        address indexed controllerObserverAddress,
        address indexed controllerObserverImplementation
    );

    constructor(address _host, address _cfa) {
        implementation = address(new EnglishRentalAuction());

        host = _host;
        cfa = _cfa;
    }

    function create(CreateParams calldata params) external returns (address auctionClone, address controllerObserverClone) {
        auctionClone = Clones.clone(implementation);
        controllerObserverClone = Clones.clone(params.controllerObserverImplementation);

        ISuperfluid(host).registerAppByFactory(ISuperApp(auctionClone), configWord);

        EnglishRentalAuction(auctionClone).initialize(
            params.acceptedToken, 
            ISuperfluid(host), 
            IConstantFlowAgreementV1(cfa), 
            IRentalAuctionControllerObserver(controllerObserverClone), 
            params.beneficiary, 
            params.minimumBidFactorWad, 
            params.reserveRate,
            params.minRentalDuration,
            params.maxRentalDuration,
            params.biddingPhaseDuration,
            params.biddingPhaseExtensionDuration
        );

        IRentalAuctionControllerObserver(controllerObserverClone).initialize(
            IRentalAuction(auctionClone),
            msg.sender,
            params.controllerObserverExtraArgs
        );

        emit EnglishRentalAuctionDeployed(auctionClone, controllerObserverClone, params.controllerObserverImplementation);
    }
}
