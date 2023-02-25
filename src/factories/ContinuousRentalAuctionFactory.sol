// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Clones } from "openzeppelin-contracts/proxy/Clones.sol";

import { ISuperfluid, SuperAppDefinitions } from "superfluid-finance/contracts/interfaces/superfluid/ISuperfluid.sol";
import { ISuperApp } from "superfluid-finance/contracts/interfaces/superfluid/ISuperApp.sol";
import { ISuperToken } from "superfluid-finance/contracts/interfaces/superfluid/ISuperToken.sol";
import { IConstantFlowAgreementV1 } from "superfluid-finance/contracts/interfaces/agreements/IConstantFlowAgreementV1.sol";

import { IRentalAuctionControllerObserver } from "../interfaces/IRentalAuctionControllerObserver.sol";
import { IRentalAuction } from "../interfaces/IRentalAuction.sol";
import { ContinuousRentalAuction } from "../ContinuousRentalAuction.sol";


/// @title ContinuousRentalAuctionFactory
/// @notice Deploys continuous rental auctions and controllers with the minimal clones proxy pattern.
contract ContinuousRentalAuctionFactory {
    /// @notice The address of the implementation of the continuous rental auction.
    address immutable implementation;

    /// @notice The address of the Superfluid host.
    address immutable host;

    /// @notice The address of the Superfluid CFA Contract.
    address immutable cfa;

    /// @notice The Superfluid config word for the continuous rental auction.
    /// @dev We want before callbacks to be noop.
    /// We want it to be APP_LEVEL_FINAL so downstream apps can't reenter.
    uint256 constant configWord = SuperAppDefinitions.APP_LEVEL_FINAL |
        SuperAppDefinitions.BEFORE_AGREEMENT_CREATED_NOOP |
        SuperAppDefinitions.BEFORE_AGREEMENT_UPDATED_NOOP |
        SuperAppDefinitions.BEFORE_AGREEMENT_TERMINATED_NOOP;

    /// @notice Emitted when a continuous rental auction is deployed.
    /// @param auctionAddress The address of the continuous rental auction
    /// @param controllerObserverAddress The address of the controller observer
    /// @param controllerObserverImplementation The address of the controller observer implementation
    event ContinuousRentalAuctionDeployed(
        address indexed auctionAddress, 
        address indexed controllerObserverAddress,
        address indexed controllerObserverImplementation
    );

    /// @notice Constructor for the factory.
    /// @param _host The address of the Superfluid host.
    /// @param _cfa The address of the Superfluid CFA contract.
    constructor(address _host, address _cfa) {
        implementation = address(new ContinuousRentalAuction());

        host = _host;
        cfa = _cfa;
    }

    /// @notice Deploys a continuous rental auction clone and a controller observer clone. Caller will be set as the owner of the controller.
    /// @param acceptedToken The accepted token for the auction.
    /// @param controllerObserverImplementation The address of the controller observer implementation.
    /// @param minimumBidFactorWad The minimum bid factor in WAD.
    /// @param reserveRate The reserve rate.
    /// @param controllerObserverExtraArgs ABI encoded additional arguments for the controller observer.
    /// @return auctionClone The address of the continuous rental auction clone.
    /// @return controllerObserverClone The address of the controller observer clone.
    function create(
        ISuperToken acceptedToken,
        address controllerObserverImplementation,
        uint96 minimumBidFactorWad,
        int96 reserveRate,
        bytes calldata controllerObserverExtraArgs
    ) external returns (address auctionClone, address controllerObserverClone) {
        // deploy clones
        auctionClone = Clones.clone(implementation);
        controllerObserverClone = Clones.clone(controllerObserverImplementation);

        // register clone as super app
        ISuperfluid(host).registerAppByFactory(ISuperApp(auctionClone), configWord);

        // initialize clones
        ContinuousRentalAuction(auctionClone).initialize(
            acceptedToken, 
            ISuperfluid(host), 
            IConstantFlowAgreementV1(cfa), 
            IRentalAuctionControllerObserver(controllerObserverClone), 
            msg.sender, // beneficiary
            minimumBidFactorWad, 
            reserveRate
        );

        IRentalAuctionControllerObserver(controllerObserverClone).initialize(
            IRentalAuction(auctionClone),
            msg.sender,
            controllerObserverExtraArgs
        );

        emit ContinuousRentalAuctionDeployed(auctionClone, controllerObserverClone, controllerObserverImplementation);
    }
}