// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol"; // TODO: REMOVE


import { SuperAppBase } from "superfluid-finance/contracts/apps/SuperAppBase.sol";
import { SuperTokenV1Library } from "superfluid-finance/contracts/apps/SuperTokenV1Library.sol";
import { ISuperfluid, SuperAppDefinitions } from "superfluid-finance/contracts/interfaces/superfluid/ISuperfluid.sol";
import { ISuperToken } from "superfluid-finance/contracts/interfaces/superfluid/ISuperToken.sol";
import { IConstantFlowAgreementV1 } from "superfluid-finance/contracts/interfaces/agreements/IConstantFlowAgreementV1.sol";

import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import { IRentalAuctionControllerObserver } from "./interfaces/IRentalAuctionControllerObserver.sol";
import { IRentalAuction } from "./interfaces/IRentalAuction.sol";


/*

english auction:

there are two phases: bidding and renting

in the bidding phase:
    anyone can place a bid (value being flowrate) if it is at least X% higher than the current highest bid
    when they place a bid:
        a deposit is taken (flowRate * minRentalDuration)
        the "bidding time" is extended by `biddingPeriodExtensionTime`

    when the bidding phase expires, it moves to the renting period
        the winning bidder idealy should immediately should get the item and be streaming to the beneficiary




    here's what would be ideal:
        in one batch do:
            approve superapp to spend daix
            approve superapp to create/update/delete flows
            call superapp function that does:
                if this is not the top bid revert
                pull daix deposit (flowRate * minRentalDuration)

                (when the bidding period is over and someone calls fn to transition to rental period it starts the flow) 
                    (also would be super sick if MEVooors were incented to call this, maybe a fee taken from someone to pay tx fee. we don't want people to have to set up keepers)

        
        this might be possible using superfluid's batch stuff check superfluid.sol line 817


    state transition:
        bidding -> renting:
            biddingPeriodEnd > 0 && biddingPeriodEnd < block.timestamp
                ^ when biddingPeriodEnd is 0 that means there are no bids yet

        renting -> bidding:
            rentingPeriodEnd < block.timestamp || "renter closed their stream"

            effects:
                return renter's deposit if they haven't gotten it already


    state in rental phase:
        the renter is streaming to app
        there may be other incoming streams to the app
        app is streaming to beneficiary

        currentWinner = renter
        topFlowRate = renter's flow rate
        senderUserData = whatever
        paused = false
        depositClaimed = true or false
        currentPhaseEndTime = time at which rental expires and bidding can start again

    state in bidding phase:
        app is NOT streaming to beneficiary
        there may be some incoming streams to the app

        currentWinner = undefined? (or 0x00?)
        topFlowRate = 0
        senderUserData = whatever
        paused = false
        depositClaimed = false
        currentPhaseEndTime = 0 if no bids yet or the time at which bidding ends if no more bids are placed close to the end





*/

contract EnglishRentalAuction is SuperAppBase, Initializable, IRentalAuction {
    // SuperToken library setup
    using SuperTokenV1Library for ISuperToken;

    /*******************************************************
     * 
     * Constants
     * 
     *******************************************************/

    ISuperToken public acceptedToken;
    ISuperfluid public host;
    IConstantFlowAgreementV1 public cfa;

    IRentalAuctionControllerObserver public controllerObserver;

    address public beneficiary;

    int96 public reserveRate;

    uint256 public minimumBidFactorWad;
    uint256 constant _wad = 1e18;

    uint256 public minRentalDuration;
    uint256 public maxRentalDuration;

    // The duration of the bidding phase once the first bid has been placed
    uint256 public biddingPhaseDuration;

    // The duration by which the bidding phase is extended if there is a bid placed with less than `biddingPhaseExtensionDuration` time left in the bidding phase
    uint256 public biddingPhaseExtensionDuration;

    /*******************************************************
     * 
     * Non constant storage
     * 
     *******************************************************/

    address public currentWinner;
    int96 public topFlowRate;

    /// @dev maps a bidder to their user data. They provide this data when placing a bid
    mapping(address => bytes) public senderUserData;

    // todo: maybe gas can be optimized here by packing in some uint8 in the same slot that is 1 or something
    uint8 private __gasThingy;
    bool public paused;
    bool public isBiddingPhase;
    // has the current renter reclaimed their deposit?
    bool public depositClaimed;

    // timestamp at which current phase ends (if 0 then we're in the bidding phase waiting for the first bid to start the countdown)
    // todo: using 1 instead of 0 might save gas
    uint256 public currentPhaseEndTime;

    /*******************************************************
     * 
     * Events
     * 
     *******************************************************/
    
    event NewTopBid(address indexed bidder, int96 flowRate);

    /*******************************************************
     * 
     * Errors
     * 
     *******************************************************/

    /// @dev Thrown when the callback caller is not the host.
    error Unauthorized();

    /// @dev Thrown when the token being streamed to this contract is invalid
    error InvalidToken();

    /// @dev Thrown when the agreement is other than the Constant Flow Agreement V1
    error InvalidAgreement();

    error FlowRateTooLow();

    error InvalidFlowRate();

    error Paused();
    error NotPaused();

    error NotBiddingPhase();

    error AlreadyInRentalPhase();
    error CurrentPhaseNotEnded();

    error AlreadyInBiddingPhase();

    error Unknown();


    function initialize(
        ISuperToken _acceptedToken,
        ISuperfluid _host,
        IConstantFlowAgreementV1 _cfa,
        IRentalAuctionControllerObserver _controllerObserver,
        address _beneficiary,
        uint96 _minimumBidFactorWad,
        int96 _reserveRate,
        uint256 _minRentalDuration,
        uint256 _maxRentalDuration, // TODO: better name for this
        uint256 _biddingPhaseDuration,
        uint256 _biddingPhaseExtensionDuration
    ) external initializer {
        require(address(_host) != address(0));
        require(address(_acceptedToken) != address(0));
        require(_beneficiary != address(0));

        require(_minimumBidFactorWad < uint256(type(uint160).max)); // prevent overflow (TODO: why is this here it makes no sense)
        require(_minimumBidFactorWad >= _wad);
        require(_reserveRate >= 0);

        require(_maxRentalDuration >= _minRentalDuration);

        // TODO: think more about minRentalDuration, it can't be too small. is 1 enough? if no, what is?

        acceptedToken = _acceptedToken;
        
        host = _host;
        cfa = _cfa;

        controllerObserver = _controllerObserver;

        beneficiary = _beneficiary;
        minimumBidFactorWad = _minimumBidFactorWad;
        reserveRate = _reserveRate;

        minRentalDuration = _minRentalDuration;
        maxRentalDuration = _maxRentalDuration;

        biddingPhaseDuration = _biddingPhaseDuration;
        biddingPhaseExtensionDuration = _biddingPhaseExtensionDuration;

        __gasThingy = 1;
        isBiddingPhase = true;
    }

    modifier onlyHost() {
        if (msg.sender != address(host)) revert Unauthorized();
        _;
    }

    modifier onlyExpected(ISuperToken superToken, address agreementClass) {
        if (superToken != acceptedToken) revert InvalidToken();
        if (agreementClass != address(cfa)) revert InvalidAgreement();
        _;
    }

    modifier onlyController() {
        if (msg.sender != address(controllerObserver)) revert Unauthorized();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    modifier whenPaused() {
        if (!paused) revert NotPaused();
        _;
    }

    modifier whenBiddingPhase() {
        // TODO: make sure this is legit
        if (!isBiddingPhase || (currentPhaseEndTime > 0 && block.timestamp >= currentPhaseEndTime)) revert NotBiddingPhase();
        _;
    }

    function isRentalPhase() external view returns (bool) {
        return !isBiddingPhase;
    }

    function isBidHigher(int96 upper, int96 lower) public view returns (bool) {
        return uint256(uint96(upper)) >= uint256(uint96(lower)) * minimumBidFactorWad / _wad;
    }

    function _placeBid(address msgSender, int96 flowRate) private {
        // check that the flowRate is valid and higher than the last bid
        if (flowRate <= 0) revert InvalidFlowRate();
        if (!isBidHigher(flowRate, topFlowRate) || flowRate < reserveRate) revert FlowRateTooLow();

        // save this user's bid
        int96 oldTopFlowRate = topFlowRate;
        topFlowRate = flowRate;

        // save this user's address as currentWinner
        address oldCurrentWinner = currentWinner;
        currentWinner = msgSender;

        // extend bidding period if close to the end or set it if it's the first bid
        if (currentPhaseEndTime == 0) {
            // this is the first bid
            currentPhaseEndTime = block.timestamp + biddingPhaseDuration;
        }
        else if (currentPhaseEndTime - block.timestamp < biddingPhaseExtensionDuration) {
            // this is not the first bid, but it is close to the end of the bidding period
            // we should extend the bidding phase
            currentPhaseEndTime += biddingPhaseExtensionDuration;
        }

        // take deposit from new bidder
        uint256 depositSize = uint96(flowRate) * minRentalDuration;
        acceptedToken.transferFrom(msgSender, address(this), depositSize);

        // return the deposit of the last bidder (if there is one)
        if (oldCurrentWinner != address(0)) {
            acceptedToken.transfer(oldCurrentWinner, uint96(oldTopFlowRate) * minRentalDuration);
        }

        emit NewTopBid(msgSender, flowRate);
    }


    // sender should have approved this contract to spend acceptedToken and manage streams for them
    // will revert if it is not approved for ERC20 transfer
    // will NOT revert if it is not authorized to manage flows. if this bidder wins the auction their deposit will be taken.
    // todo: maybe make another version of this function that doesn't need to get called by the host
    // todo: userData
    function placeBid(int96 flowRate, bytes calldata _ctx) external onlyHost whenBiddingPhase returns (bytes memory) {
        address msgSender = host.decodeCtx(_ctx).msgSender;
        
        _placeBid(msgSender, flowRate);

        return _ctx;
    }
    function placeBid(int96 flowRate) external whenBiddingPhase {
        _placeBid(msg.sender, flowRate);
    }

    // starting state in rental phase:
    //     the renter is streaming to app
    //     there may be other incoming streams to the app
    //     app is streaming to beneficiary

    //     currentWinner = renter
    //     topFlowRate = renter's flow rate
    //     senderUserData = whatever
    //     paused = false
    //     depositClaimed = false
    //     currentPhaseEndTime = time at which rental expires and bidding can start again

    // ending state in rental phase:
    //     the renter is streaming to app
    //     there may be other incoming streams to the app
    //     app is streaming to beneficiary

    //     currentWinner = renter
    //     topFlowRate = renter's flow rate
    //     senderUserData = whatever
    //     paused = false
    //     depositClaimed = true or false
    //     currentPhaseEndTime = time at which rental expires and bidding can start again

    // starting state in bidding phase:
    //     app is NOT streaming to beneficiary
    //     there may be some incoming streams to the app

    //     currentWinner = undefined? (or 0x00?)
    //     topFlowRate = 0
    //     senderUserData = whatever
    //     paused = false
    //     depositClaimed = false
    //     currentPhaseEndTime = 0

    // ending state in bidding phase:
    //     app is NOT streaming to beneficiary
    //     there may be some incoming streams to the app

    //     currentWinner = the next renter
    //     topFlowRate = next renter's rate
    //     senderUserData = whatever
    //     paused = false
    //     depositClaimed = false
    //     currentPhaseEndTime = time at which bidding ended

    function transitionToRentalPhase() external {
        if (!isBiddingPhase) revert AlreadyInRentalPhase();

        // if currentPhaseEndTime > 0 then topFlowRate and currentWinner must be set correctly
        if (currentPhaseEndTime == 0 || block.timestamp < currentPhaseEndTime) revert CurrentPhaseNotEnded();

        // try create flow from winner to app
        // it can fail if the winner has not approved the app as a flow operator
        // if it does fail, take their deposit and restart bidding phase
        try host.callAgreement(
            cfa,
            abi.encodeCall(
                cfa.createFlowByOperator,
                (acceptedToken, currentWinner, address(this), topFlowRate, new bytes(0))
            ),
            new bytes(0)
        ) {
            // afterAgreementCreated is triggered, which does the state transition to the renting phase
        }
        catch {
            // restart bidding phase

            topFlowRate = 0;
            currentPhaseEndTime = 0;

            // todo: send their deposit to beneficiary
        }

        // todo: explore how to pay the caller of this function (maybe with the deposit?)
    }

    function transitionToBiddingPhase() external {
        if (isBiddingPhase) revert AlreadyInBiddingPhase();

        if (block.timestamp < currentPhaseEndTime) revert CurrentPhaseNotEnded();

        // delete flow to beneficiary (not reentrant)
        acceptedToken.deleteFlow(address(this), beneficiary);

        // return deposit (not reentrant)
        if (!depositClaimed) {
            acceptedToken.transfer(currentWinner, uint96(topFlowRate) * minRentalDuration); 
        } 
        else {
            depositClaimed = false;
        }

        // set state variables for beginning of bidding phase
        isBiddingPhase = true;
        
        currentPhaseEndTime = 0;
        topFlowRate = 0;

        // delete flow from current renter (for some reason this DOES NOT trigger afterAgreementTerminated callback) (not reentrant)
        // THIS CAN FAIL (maybe the currentWinner revoked this app's flow operator role)
        try host.callAgreement(
            cfa,
            abi.encodeCall(
                cfa.deleteFlow,
                (acceptedToken, currentWinner, address(this), new bytes(0))
            ),
            new bytes(0)
        ) {}
        catch {
            // the incoming flow from the currentWinner has NOT been terminated
            // they will continue streaming into this superapp, but we transition to bidding phase anyway
            // TODO: there is a function where anyone can send acceptedToken stuck in this contract to the beneficiary (be sure to account for legit deposits)
        }

        controllerObserver.onWinnerChanged(address(0));
    }

    // function beforeAgreementCreated(
    //     ISuperToken _superToken,
    //     address _agreementClass,
    //     bytes32 /*agreementId*/,
    //     bytes calldata /*agreementData*/,
    //     bytes calldata /*ctx*/
    // )
    //     external
    //     view
    //     virtual
    //     override
    //     onlyExpected(_superToken, _agreementClass)
    //     returns (bytes memory /*cbdata*/) {}

    function afterAgreementCreated(
        ISuperToken /*superToken*/,
        address /*agreementClass*/,
        bytes32 /*agreementId*/,
        bytes calldata /*agreementData*/,
        bytes calldata /*cbdata*/,
        bytes calldata _ctx
    )
        external
        virtual
        override
        onlyHost
        returns (bytes memory newCtx)
    {
        if (host.decodeCtx(_ctx).msgSender != address(this)) revert Unknown(); // todo name this

        // stream sender must be the currentWinner and we are transitioning to the rental phase

        isBiddingPhase = false;

        currentPhaseEndTime = block.timestamp + maxRentalDuration;

        newCtx = acceptedToken.createFlowWithCtx(beneficiary, topFlowRate, _ctx);

        controllerObserver.onWinnerChanged(currentWinner);
    }


    

    function afterAgreementTerminated(
        ISuperToken _superToken,
        address _agreementClass,
        bytes32, // _agreementId,
        bytes calldata, // _agreementData
        bytes calldata, // _cbdata,
        bytes calldata _ctx
    ) external override onlyHost returns (bytes memory newCtx) {
        console.log("afterAgreementTerminated");
        // According to the app basic law, we should never revert in a termination callback
        if (_superToken != acceptedToken || _agreementClass != address(cfa)) {
            // TODO: this condition may be unnecessary because only this app can initiate streams to itself
            return _ctx;
        }

        newCtx = _ctx;

        address msgSender = host.decodeCtx(newCtx).msgSender;

        // if we are not in renting phase or msgSender is not currentWinner, then do nothing

        if (!isBiddingPhase && msgSender == currentWinner) {
            // the current renter has terminated their stream

            // set state variables for beginning of bidding phase
            isBiddingPhase = true;
            
            currentPhaseEndTime = 0;
            topFlowRate = 0;
            depositClaimed = false;

            // delete flow to beneficiary
            acceptedToken.deleteFlow(address(this), beneficiary);

            // TODO: return deposit (or part of it)

            controllerObserver.onWinnerChanged(address(0));
        }
    }

    /*******************************************************
     * 
     * RentalAuctionControllerObserver functions
     * 
     *******************************************************/

    function pause() external onlyController whenNotPaused {
        
    }

    function unpause() external onlyController whenPaused {
        
    }
}
