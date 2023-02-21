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

// TODO: optimize storage and just generally

contract EnglishRentalAuction is SuperAppBase, Initializable, IRentalAuction {
    // SuperToken library setup
    using SuperTokenV1Library for ISuperToken;

    /*******************************************************
     * 
     * Constants
     * 
     *******************************************************/
    uint256 constant _wad = 1e18;

    ISuperToken public acceptedToken;
    ISuperfluid public host;
    IConstantFlowAgreementV1 public cfa;

    IRentalAuctionControllerObserver public controllerObserver;

    address public beneficiary;

    int96 public reserveRate;

    uint256 public minimumBidFactorWad;

    uint64 public minRentalDuration;
    uint64 public maxRentalDuration;

    // The duration of the bidding phase once the first bid has been placed
    uint64 public biddingPhaseDuration;

    // The duration by which the bidding phase is extended if there is a bid placed with less than `biddingPhaseExtensionDuration` time left in the bidding phase
    uint64 public biddingPhaseExtensionDuration;

    /*******************************************************
     * 
     * Non constant storage
     * 
     *******************************************************/

    address public topBidder;
    int96 public topFlowRate;

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

    event DepositClaimed(address indexed renter, uint256 amount);

    event TransitionedToRentalPhase(address indexed renter, int96 flowRate);

    event TransitionedToBiddingPhase();

    event TransitionToRentalPhaseFailed(address indexed topBidder, int96 flowRate);

    event TransitionedToBiddingPhaseEarly(address indexed renter, int96 flowRate);

    event Unpaused();

    event Paused(address indexed topBidder, int96 flowRate);

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

    error IsPaused();
    error IsNotPaused();

    error NotBiddingPhase();
    error NotRentalPhase();

    error AlreadyInRentalPhase();
    error CurrentPhaseNotEnded();

    error AlreadyInBiddingPhase();

    error DepositAlreadyClaimed();
    error TooEarlyToReclaimDeposit();

    error BeneficiaryCannotBid();

    error Unknown();

    event Initialized(
        address acceptedToken, 
        address controllerObserver, 
        address beneficiary,
        uint96 minimumBidFactorWad,
        int96 reserveRate,
        uint64 minRentalDuration,
        uint64 maxRentalDuration,
        uint64 biddingPhaseDuration,
        uint64 biddingPhaseExtensionDuration
    );

    function initialize(
        ISuperToken _acceptedToken,
        ISuperfluid _host,
        IConstantFlowAgreementV1 _cfa,
        IRentalAuctionControllerObserver _controllerObserver,
        address _beneficiary,
        uint96 _minimumBidFactorWad,
        int96 _reserveRate,
        uint64 _minRentalDuration,
        uint64 _maxRentalDuration, // TODO: better name for this
        uint64 _biddingPhaseDuration,
        uint64 _biddingPhaseExtensionDuration
    ) external initializer {
        require(address(_acceptedToken) != address(0));
        require(address(_host) != address(0));
        require(address(_cfa) != address(0));

        require(_beneficiary != address(0));

        // require(_minimumBidFactorWad < uint256(type(uint160).max));
        require(_minimumBidFactorWad >= _wad);
        require(_reserveRate >= 0);

        require(_minRentalDuration > 0);
        require(_maxRentalDuration >= _minRentalDuration);

        require(_biddingPhaseExtensionDuration > 0);
        require(_biddingPhaseDuration >= _biddingPhaseExtensionDuration);

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
        paused = true;

        emit Initialized(
            address(_acceptedToken), 
            address(_controllerObserver), 
            _beneficiary,
            _minimumBidFactorWad,
            _reserveRate,
            _minRentalDuration,
            _maxRentalDuration,
            _biddingPhaseDuration,
            _biddingPhaseExtensionDuration
        );
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
        if (paused) revert IsPaused();
        _;
    }

    modifier whenPaused() {
        if (!paused) revert IsNotPaused();
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
        return uint256(uint96(upper)) > uint256(uint96(lower)) * minimumBidFactorWad / _wad;
    }

    function currentRenter() public view returns (address) {
        return isBiddingPhase ? address(0) : topBidder;
    }

    function _placeBid(address msgSender, int96 flowRate) private {
        // check that the flowRate is valid and higher than the last bid
        if (flowRate <= 0) revert InvalidFlowRate();
        if (!isBidHigher(flowRate, topFlowRate) || flowRate < reserveRate) revert FlowRateTooLow();
        if (msgSender == beneficiary) revert BeneficiaryCannotBid();

        // save this user's bid
        int96 oldTopFlowRate = topFlowRate;
        topFlowRate = flowRate;

        // save this user's address as topBidder
        address oldTopBidder = topBidder;
        topBidder = msgSender;

        // extend bidding period if close to the end or set it if it's the first bid
        if (currentPhaseEndTime == 0) {
            // this is the first bid
            currentPhaseEndTime = block.timestamp + biddingPhaseDuration;
        }
        else if (currentPhaseEndTime - block.timestamp < biddingPhaseExtensionDuration) {
            // this is not the first bid, but it is close to the end of the bidding period
            // we should extend the bidding phase
            currentPhaseEndTime = block.timestamp + biddingPhaseExtensionDuration;
        }

        // take deposit from new bidder
        uint256 depositSize = uint96(flowRate) * uint256(minRentalDuration);
        acceptedToken.transferFrom(msgSender, address(this), depositSize);

        // return the deposit of the last bidder (if there is one)
        if (oldTopFlowRate != 0) {
            acceptedToken.transfer(oldTopBidder, uint96(oldTopFlowRate) * uint256(minRentalDuration));
        }

        emit NewTopBid(msgSender, flowRate);
    }


    // sender should have approved this contract to spend acceptedToken and manage streams for them
    // will revert if it is not approved for ERC20 transfer
    // will NOT revert if it is not authorized to manage flows. if this bidder wins the auction their deposit will be taken.
    function placeBid(int96 flowRate, bytes calldata _ctx) external onlyHost whenBiddingPhase whenNotPaused returns (bytes memory) {
        address msgSender = host.decodeCtx(_ctx).msgSender;
        
        _placeBid(msgSender, flowRate);

        return _ctx;
    }
    function placeBid(int96 flowRate) external whenBiddingPhase whenNotPaused {
        _placeBid(msg.sender, flowRate);
    }

    function reclaimDeposit() external whenNotPaused {
        if (isBiddingPhase) revert NotRentalPhase();

        address _topBidder = topBidder;

        if (msg.sender != _topBidder) revert Unauthorized();

        if (depositClaimed) revert DepositAlreadyClaimed();

        uint256 rentalStartTs = currentPhaseEndTime - maxRentalDuration;
        if (block.timestamp < rentalStartTs + minRentalDuration) revert TooEarlyToReclaimDeposit();

        depositClaimed = true;
        uint256 depositSize = uint96(topFlowRate) * uint256(minRentalDuration);

        acceptedToken.transfer(_topBidder, depositSize);

        emit DepositClaimed(_topBidder, depositSize);
    }

    // starting state in rental phase:
    //     the renter is streaming to app
    //     there may be other incoming streams to the app
    //     app is streaming to beneficiary

    //     currentRenter = renter
    //     topFlowRate = renter's flow rate
    //     paused = false
    //     depositClaimed = false
    //     currentPhaseEndTime = time at which rental expires and bidding can start again

    // ending state in rental phase:
    //     the renter is streaming to app
    //     there may be other incoming streams to the app
    //     app is streaming to beneficiary

    //     currentRenter = renter
    //     topFlowRate = renter's flow rate
    //     paused = false
    //     depositClaimed = true or false
    //     currentPhaseEndTime = time at which rental expires and bidding can start again

    // starting state in bidding phase:
    //     app is NOT streaming to beneficiary
    //     there may be some incoming streams to the app

    //     currentRenter = undefined? (or 0x00?)
    //     topFlowRate = 0
    //     paused = false
    //     depositClaimed = false
    //     currentPhaseEndTime = 0

    // ending state in bidding phase:
    //     app is NOT streaming to beneficiary
    //     there may be some incoming streams to the app

    //     currentRenter = the next renter
    //     topFlowRate = next renter's rate
    //     paused = false
    //     depositClaimed = false
    //     currentPhaseEndTime = time at which bidding ended

    function transitionToRentalPhase() external whenNotPaused {
        if (!isBiddingPhase) revert AlreadyInRentalPhase();

        // if currentPhaseEndTime > 0 then topFlowRate and currentRenter must be set correctly
        if (currentPhaseEndTime == 0 || block.timestamp < currentPhaseEndTime) revert CurrentPhaseNotEnded();

        // try create flow from renter to app
        // it can fail if the renter has not approved the app as a flow operator
        // if it does fail, take their deposit and restart bidding phase
        int96 _topFlowRate = topFlowRate;
        address _topBidder = topBidder;
        try host.callAgreement(
            cfa,
            abi.encodeCall(
                cfa.createFlowByOperator,
                (acceptedToken, _topBidder, address(this), _topFlowRate, new bytes(0))
            ),
            new bytes(0)
        ) {
            // afterAgreementCreated is triggered, which does the state transition to the renting phase
        }
        catch {
            // send their deposit to beneficiary
            acceptedToken.transfer(beneficiary, uint96(_topFlowRate) * uint256(minRentalDuration));

            // restart bidding phase
            topFlowRate = 0;
            currentPhaseEndTime = 0;

            emit TransitionToRentalPhaseFailed(_topBidder, _topFlowRate);
        }

        // todo: explore how to pay the caller of this function (maybe with the deposit?)
    }

    function transitionToBiddingPhase() external whenNotPaused {
        if (isBiddingPhase) revert AlreadyInBiddingPhase();

        if (block.timestamp < currentPhaseEndTime) revert CurrentPhaseNotEnded();

        // delete flow to beneficiary (not reentrant)
        acceptedToken.deleteFlow(address(this), beneficiary);

        // return deposit (not reentrant)
        if (!depositClaimed) {
            acceptedToken.transfer(topBidder, uint96(topFlowRate) * uint256(minRentalDuration)); 
        }

        // set state variables for beginning of bidding phase
        isBiddingPhase = true;
        depositClaimed = false;
        
        currentPhaseEndTime = 0;
        topFlowRate = 0;

        // delete flow from current renter (for some reason this DOES NOT trigger afterAgreementTerminated callback) (not reentrant)
        // THIS CAN FAIL (maybe the currentRenter revoked this app's flow operator role)
        try host.callAgreement(
            cfa,
            abi.encodeCall(
                cfa.deleteFlow,
                (acceptedToken, topBidder, address(this), new bytes(0))
            ),
            new bytes(0)
        ) {}
        catch {
            // the incoming flow from the currentRenter has NOT been terminated
            // they will continue streaming into this superapp, but we transition to bidding phase anyway
            // TODO: there is a function where anyone can send acceptedToken stuck in this contract to the beneficiary (be sure to account for legit deposits)
        }

        if (address(controllerObserver) != address(0)) controllerObserver.onRenterChanged(address(0));

        emit TransitionedToBiddingPhase();
    }

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

        // stream sender must be the currentRenter and we are transitioning to the rental phase

        address _topBidder = topBidder;
        int96 _topFlowRate = topFlowRate;

        isBiddingPhase = false;

        currentPhaseEndTime = block.timestamp + maxRentalDuration;

        newCtx = acceptedToken.createFlowWithCtx(beneficiary, _topFlowRate, _ctx);

        if (address(controllerObserver) != address(0)) controllerObserver.onRenterChanged(_topBidder);
        
        emit TransitionedToRentalPhase(_topBidder, _topFlowRate);
    }


    

    function afterAgreementTerminated(
        ISuperToken _superToken,
        address _agreementClass,
        bytes32, // _agreementId,
        bytes calldata _agreementData,
        bytes calldata, // _cbdata,
        bytes calldata _ctx
    ) external override onlyHost returns (bytes memory newCtx) {
        console.log("afterAgreementTerminated");
        // According to the app basic law, we should never revert in a termination callback
        if (_superToken != acceptedToken || _agreementClass != address(cfa)) {
            // Is this necessary? could IDA trigger this?
            return _ctx;
        }

        newCtx = _ctx;

        address _topBidder = topBidder;
        int96 _topFlowRate = topFlowRate;

        (address streamSender,) = abi.decode(_agreementData, (address,address));

        // if we are not in renting phase or msgSender is not currentRenter, then do nothing
        if (!isBiddingPhase && streamSender == _topBidder) {
            // the current renter has terminated their stream
            
            // delete flow to beneficiary (not reentrant)
            newCtx = acceptedToken.deleteFlowWithCtx(address(this), beneficiary, newCtx);

            // return deposit (or part of it)
            if (!depositClaimed) {
                uint256 streamedAmount = uint96(_topFlowRate) * (block.timestamp + maxRentalDuration - currentPhaseEndTime );
                uint256 depositSize = uint96(_topFlowRate) * uint256(minRentalDuration);

                if (streamedAmount >= depositSize) {
                    // not reentrant
                    acceptedToken.transfer(streamSender, depositSize);
                }
                else {
                    acceptedToken.transfer(beneficiary, depositSize - streamedAmount);
                    acceptedToken.transfer(streamSender, streamedAmount);
                }
            }

            // set state variables for beginning of bidding phase (TODO: easy to optimize a little bit, end time can be uint160 probs)
            isBiddingPhase = true;
            currentPhaseEndTime = 0;
            topFlowRate = 0;
            depositClaimed = false;

            if (address(controllerObserver) != address(0)) controllerObserver.onRenterChanged(address(0));

            emit TransitionedToBiddingPhaseEarly(_topBidder, _topFlowRate);
        }
    }

    /*******************************************************
     * 
     * RentalAuctionControllerObserver functions
     * 
     *******************************************************/

    function pause() external onlyController whenNotPaused whenBiddingPhase {
        paused = true;

        address _topBidder = topBidder;
        int96 _topFlowRate = topFlowRate;

        // refund any deposit
        if (_topFlowRate > 0) {
            acceptedToken.transfer(_topBidder, uint96(_topFlowRate) * uint256(minRentalDuration));
        }

        // set state variables to be beginning of bidding phase
        isBiddingPhase = true;
        depositClaimed = false;
        
        currentPhaseEndTime = 0;
        topFlowRate = 0;

        emit Paused(_topBidder, _topFlowRate);
    }

    function unpause() external onlyController whenPaused {
        paused = false;

        emit Unpaused();
    }
}
