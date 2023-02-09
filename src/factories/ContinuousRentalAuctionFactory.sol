// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

import { ISuperfluid, SuperAppDefinitions } from "superfluid-finance/contracts/interfaces/superfluid/ISuperfluid.sol";
import { ISuperApp } from "superfluid-finance/contracts/interfaces/superfluid/ISuperApp.sol";
import { ISuperToken } from "superfluid-finance/contracts/interfaces/superfluid/ISuperToken.sol";
import { IConstantFlowAgreementV1 } from "superfluid-finance/contracts/interfaces/agreements/IConstantFlowAgreementV1.sol";

import { IRentalAuctionControllerObserver } from "../interfaces/IRentalAuctionControllerObserver.sol";
import { IRentalAuction } from "../interfaces/IRentalAuction.sol";
import { ContinuousRentalAuction } from "../ContinuousRentalAuction.sol";


contract ContinuousRentalAuctionFactory {
    address immutable implementation;

    address immutable host;
    address immutable cfa;

    uint256 constant configWord = SuperAppDefinitions.APP_LEVEL_FINAL | // TODO: for now assume final, later figure out how to remove this requirement safely
        SuperAppDefinitions.BEFORE_AGREEMENT_CREATED_NOOP |
        SuperAppDefinitions.BEFORE_AGREEMENT_UPDATED_NOOP |
        SuperAppDefinitions.BEFORE_AGREEMENT_TERMINATED_NOOP;

    event ContinuousRentalAuctionDeployed(
        address indexed auctionAddress, 
        address indexed controllerObserverAddress,
        address indexed controllerObserverImplementation
    );

    constructor(address _host, address _cfa) {
        implementation = address(new ContinuousRentalAuction());

        host = _host;
        cfa = _cfa;
    }

    function create(
        ISuperToken _acceptedToken,
        address _controllerObserverImplementation,
        address _beneficiary,
        uint96 _minimumBidFactorWad,
        int96 _reserveRate,
        bytes calldata _controllerObserverExtraArgs
    ) external returns (address auctionClone, address controllerObserverClone) {
        // TODO: make sure acceptedToken is actually a supertoken

        auctionClone = Clones.clone(implementation);
        controllerObserverClone = Clones.clone(_controllerObserverImplementation);

        ISuperfluid(host).registerAppByFactory(ISuperApp(auctionClone), configWord);

        ContinuousRentalAuction(auctionClone).initialize(
            _acceptedToken, 
            ISuperfluid(host), 
            IConstantFlowAgreementV1(cfa), 
            IRentalAuctionControllerObserver(controllerObserverClone), 
            _beneficiary, 
            _minimumBidFactorWad, 
            _reserveRate
        );

        IRentalAuctionControllerObserver(controllerObserverClone).initialize(
            IRentalAuction(auctionClone),
            _controllerObserverExtraArgs
        );

        emit ContinuousRentalAuctionDeployed(auctionClone, controllerObserverClone, _controllerObserverImplementation);
    }
}