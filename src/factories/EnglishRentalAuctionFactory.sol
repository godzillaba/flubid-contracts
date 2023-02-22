// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Clones } from "openzeppelin-contracts/proxy/Clones.sol";

import { ISuperfluid, ISuperApp, ISuperToken, SuperAppDefinitions } from "superfluid-finance/contracts/interfaces/superfluid/ISuperfluid.sol";
import { IConstantFlowAgreementV1 } from "superfluid-finance/contracts/interfaces/agreements/IConstantFlowAgreementV1.sol";

import { EnglishRentalAuction } from "../EnglishRentalAuction.sol";
import { IRentalAuction } from "../interfaces/IRentalAuction.sol";
import { IRentalAuctionControllerObserver } from "../interfaces/IRentalAuctionControllerObserver.sol";

/// @title EnglishRentalAuctionFactory
/// @notice Deploys English rental auctions and controllers with the minimal clones proxy pattern.
contract EnglishRentalAuctionFactory {
    /// @notice The address of the implementation of the English rental auction.
    address immutable implementation;

    /// @notice The address of the Superfluid host.
    address immutable host;
    /// @notice The address of the Superfluid CFA Contract.
    address immutable cfa;

    /// @notice The Superfluid config word for the English rental auction.
    /// @dev We want to support after creation, revert on updating, after termination.
    /// We want it to be APP_LEVEL_FINAL so downstream apps can't reenter.
    uint256 constant configWord = SuperAppDefinitions.APP_LEVEL_FINAL |
        SuperAppDefinitions.BEFORE_AGREEMENT_CREATED_NOOP |
        SuperAppDefinitions.AFTER_AGREEMENT_UPDATED_NOOP |
        SuperAppDefinitions.BEFORE_AGREEMENT_TERMINATED_NOOP;

    /// @notice The parameters for creating an English rental auction.
    /// @param acceptedToken The accepted token for the auction.
    /// @param controllerObserverImplementation The address of the controller observer implementation.
    /// @param beneficiary The beneficiary of the auction.
    /// @param minimumBidFactorWad The minimum bid factor in WAD.
    /// @param reserveRate The reserve rate.
    /// @param minRentalDuration The minimum rental duration.
    /// @param maxRentalDuration The maximum rental duration.
    /// @param biddingPhaseDuration The bidding phase duration.
    /// @param biddingPhaseExtensionDuration The bidding phase extension duration.
    /// @param controllerObserverExtraArgs Extra arguments for the controller observer.
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

    /// @notice Emitted when an English rental auction is deployed.
    /// @param auctionAddress The address of the deployed auction clone.
    /// @param controllerObserverAddress The address of the deployed controller observer clone.
    /// @param controllerObserverImplementation The address of the controller observer implementation.
    event EnglishRentalAuctionDeployed(
        address indexed auctionAddress, 
        address indexed controllerObserverAddress,
        address indexed controllerObserverImplementation
    );

    /// @notice Factory constructor.
    /// @param _host The address of the Superfluid host.
    /// @param _cfa The address of the Superfluid CFA Contract.
    constructor(address _host, address _cfa) {
        implementation = address(new EnglishRentalAuction());

        host = _host;
        cfa = _cfa;
    }

    /// @notice Create a new English rental auction and controller using the minimal clones proxy pattern. 
    /// Caller will be set as the owner of the controller.
    /// @param params The parameters for creating the auction.
    /// @return auctionClone The address of the auction clone.
    /// @return controllerObserverClone The address of the controller observer clone.
    function create(CreateParams calldata params) external returns (address auctionClone, address controllerObserverClone) {
        // deploy clones
        auctionClone = Clones.clone(implementation);
        controllerObserverClone = Clones.clone(params.controllerObserverImplementation);

        // register clone as super app
        ISuperfluid(host).registerAppByFactory(ISuperApp(auctionClone), configWord);

        // initialize clones
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
