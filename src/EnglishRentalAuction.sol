// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { SuperAppBase } from "superfluid-finance/contracts/apps/SuperAppBase.sol";
import { SuperTokenV1Library } from "superfluid-finance/contracts/apps/SuperTokenV1Library.sol";
import { ISuperfluid, ISuperApp } from "superfluid-finance/contracts/interfaces/superfluid/ISuperfluid.sol";
import { ISuperToken } from "superfluid-finance/contracts/interfaces/superfluid/ISuperToken.sol";
import { IConstantFlowAgreementV1 } from "superfluid-finance/contracts/interfaces/agreements/IConstantFlowAgreementV1.sol";

import { Initializable } from "openzeppelin-contracts/proxy/utils/Initializable.sol";

import { IRentalAuctionControllerObserver } from "./interfaces/IRentalAuctionControllerObserver.sol";
import { IRentalAuction } from "./interfaces/IRentalAuction.sol";


/// @title EnglishRentalAuction
/// @notice An english rental auction that takes payment in Superfluid streams.
/// The auction has two phases: bidding and rental. 
/// During the bidding phase anyone (except the auction beneficiary) 
/// can place a flow rate bid if it is at least the reserve rate and at least `minimumBidFactorWad` times the current top bid.
/// When a bid is placed, a deposit of SuperTokens is taken from the bidder and held by the auction contract (`flowRate * minRentalDuration`).
/// When the bidding phase ends, the auction transitions to the rental phase.
/// Transitioning to the rental phase starts a stream from the top bidder to the auction contract 
/// as well as a stream from the auction contract to the beneficiary at the top bid rate.
/// If the renter does not close their stream before the minimum rental duration elapses, they can get their deposit back.
/// If the renter closes their stream before the minimum rental duration elapses, a portion of their deposit is sent to the beneficiary.
/// Once the maximum rental duration elapses, the auction transitions back to the bidding phase.
contract EnglishRentalAuction is SuperAppBase, Initializable, IRentalAuction {
    // SuperToken library setup
    using SuperTokenV1Library for ISuperToken;

    /*******************************************************
     * 
     * Constants
     * 
     *******************************************************/
    uint256 constant _wad = 1e18;

    /// @notice Token that is accepted by the auction
    ISuperToken public acceptedToken;
    /// @notice The Superfluid host
    ISuperfluid public host;
    /// @notice The Superfluid CFA contract
    IConstantFlowAgreementV1 public cfa;

    /// @notice The controller observer for this auction
    IRentalAuctionControllerObserver public controllerObserver;

    /// @notice The auction beneficiary. Receives the proceeds of the auction.
    address public beneficiary;

    /// @notice The minimum flow rate that can be bid
    int96 public reserveRate;

    /// @notice The minimum factor by which the top bid must be increased
    uint256 public minimumBidFactorWad;

    /// @notice The minimum rental duration. 
    /// Any renter that terminates their stream before this duration elapses will lose some of their deposit.
    uint64 public minRentalDuration;
    /// @notice The maximum rental duration.
    /// The auction can transition back to the bidding phase after this duration elapses.
    uint64 public maxRentalDuration;

    /// @notice The duration of the bidding phase once the first bid has been placed
    uint64 public biddingPhaseDuration;

    /// @notice The minimum amount of time between a bid being placed and the auction transitioning to the rental phase
    /// @dev If a bid is placed with `currentPhaseEndTime - block.timestamp < biddingPhaseExtensionDuration`,
    /// `currentPhaseEndTime` becomes `block.timestamp + biddingPhaseExtensionDuration`
    uint64 public biddingPhaseExtensionDuration;

    /*******************************************************
     * 
     * Non constant storage
     * 
     *******************************************************/

    /// @notice Address of the top bidder (if bidding phase) or renter (if rental phase)
    address public topBidder;
    /// @notice The top bid (if bidding phase) or rental rate (if rental phase)
    int96 public topFlowRate;

    /// @dev Set to 1 to save gas when transitioning phase/pausing/claiming deposit
    uint8 private __gasThingy;

    /// @notice Whether the auction is paused
    bool public paused;

    /// @notice Whether the auction is in the bidding phase
    bool public isBiddingPhase;

    /// @notice Whether the renter's deposit has been reclaimed
    bool public depositClaimed;

    /// @notice timestamp at which current phase ends (if 0 then we're in the bidding phase waiting for the first bid to start the countdown)
    uint256 public currentPhaseEndTime;

    /*******************************************************
     * 
     * Events
     * 
     *******************************************************/
    
    /// @notice Emitted when a new top bid is placed
    /// @param bidder The address of the bidder
    /// @param flowRate The flow rate of the bid
    event NewTopBid(address indexed bidder, int96 flowRate);

    /// @notice Emitted when the renter reclaims their deposit
    /// @param renter The address of the renter
    /// @param amount The amount of tokens reclaimed
    event DepositClaimed(address indexed renter, uint256 amount);

    /// @notice Emitted when the auction transitions to the rental phase
    /// @param renter The address of the renter
    /// @param flowRate The flow rate of the rental
    event TransitionedToRentalPhase(address indexed renter, int96 flowRate);

    /// @notice Emitted when the auction transitions to the bidding phase
    event TransitionedToBiddingPhase();

    /// @notice Emitted when transitioning to the rental phase fails. 
    /// The top bidder's deposit is send to the beneficiary and the bidding phase restarts.
    /// @param topBidder The address of the top bidder
    /// @param flowRate The flow rate of the top bid
    event TransitionToRentalPhaseFailed(address indexed topBidder, int96 flowRate);

    /// @notice Emitted when the auction transitions to the bidding phase because the renter closes their stream.
    /// @param renter The address of the renter
    /// @param flowRate The flow rate of the rental
    event TransitionedToBiddingPhaseEarly(address indexed renter, int96 flowRate);

    /// @notice Emitted when the auction is unpaused
    event Unpaused();

    /// @notice Emitted when the auction is paused
    /// @param topBidder The address of the top bidder at the time of pausing
    /// @param flowRate The flow rate of the top bid at the time of pausing
    event Paused(address indexed topBidder, int96 flowRate);

    /*******************************************************
     * 
     * Errors
     * 
     *******************************************************/

    error Unauthorized();
    error InvalidToken();
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
    error SuperAppCannotBid();

    /// @notice Initializes the auction
    /// @param _acceptedToken The token that is accepted by the auction
    /// @param _host The Superfluid host
    /// @param _cfa The Superfluid CFA contract
    /// @param _controllerObserver The controller observer for this auction
    /// @param _beneficiary The auction beneficiary. Receives the proceeds of the auction.
    /// @param _minimumBidFactorWad The minimum factor by which the top bid must be increased
    /// @param _reserveRate The minimum flow rate that can be bid
    /// @param _minRentalDuration The minimum rental duration.
    /// @param _maxRentalDuration The maximum rental duration.
    /// @param _biddingPhaseDuration The duration of the bidding phase once the first bid has been placed
    /// @param _biddingPhaseExtensionDuration The minimum amount of time between a bid being placed and the auction transitioning to the rental phase
    function initialize(
        ISuperToken _acceptedToken,
        ISuperfluid _host,
        IConstantFlowAgreementV1 _cfa,
        IRentalAuctionControllerObserver _controllerObserver,
        address _beneficiary,
        uint96 _minimumBidFactorWad,
        int96 _reserveRate,
        uint64 _minRentalDuration,
        uint64 _maxRentalDuration,
        uint64 _biddingPhaseDuration,
        uint64 _biddingPhaseExtensionDuration
    ) external initializer {
        require(address(_acceptedToken) != address(0));
        require(address(_host) != address(0));
        require(address(_cfa) != address(0));

        require(_beneficiary != address(0));
        require(!_host.isApp(ISuperApp(_beneficiary)));

        require(_minimumBidFactorWad >= _wad);
        require(_reserveRate >= 0);

        require(_minRentalDuration > 0);
        require(_maxRentalDuration >= _minRentalDuration);

        require(_biddingPhaseExtensionDuration > 0);
        require(_biddingPhaseDuration >= _biddingPhaseExtensionDuration);

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
    }

    modifier onlyHost() {
        if (msg.sender != address(host)) revert Unauthorized();
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
        if (!isBiddingPhase || (currentPhaseEndTime > 0 && block.timestamp >= currentPhaseEndTime)) revert NotBiddingPhase();
        _;
    }

    /// @notice Places a bid. This function is only callable by the Superfluid host.
    /// @param flowRate The flow rate of the bid
    /// @param _ctx The Superfluid context
    /// @return The Superfluid context
    function placeBid(int96 flowRate, bytes calldata _ctx) external onlyHost whenBiddingPhase whenNotPaused returns (bytes memory) {
        address msgSender = host.decodeCtx(_ctx).msgSender;
        
        _placeBid(msgSender, flowRate);

        return _ctx;
    }

    /// @notice Places a bid.
    /// @param flowRate The flow rate of the bid
    function placeBid(int96 flowRate) external whenBiddingPhase whenNotPaused {
        _placeBid(msg.sender, flowRate);
    }

    /// @notice Reclaim rental/bid deposit
    /// This function can only be called by the current renter.
    /// The minimum rental duration must have passed.
    function reclaimDeposit() external {
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

    /// @notice Transitions the auction to the rental phase.
    /// @dev The auction must not be in the rental phase and the current phase must have ended.
    /// We try to create a flow from the top bidder to the app. If it fails, we take their deposit and restart the bidding phase.
    /// If it succeeds, we transition to the rental phase.
    function transitionToRentalPhase() external {
        if (!isBiddingPhase) revert AlreadyInRentalPhase();

        // if we haven't gotten any bids yet or the bidding phase hasn't ended yet, revert
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
            // afterAgreementCreated is triggered, which does the state transition to the renting phase.
            // we have to create the beneficiary flow in the callback. If we try to do it here it won't work.
        }
        catch {
            // send their deposit to beneficiary
            acceptedToken.transfer(beneficiary, uint96(_topFlowRate) * uint256(minRentalDuration));

            // restart bidding phase
            topFlowRate = 0;
            currentPhaseEndTime = 0;

            emit TransitionToRentalPhaseFailed(_topBidder, _topFlowRate);
        }
    }

    /// @notice Transitions the auction to the bidding phase.
    /// @dev The auction must be in the rental phase and the max rental duration must have passed.
    /// Return the deposit to the renter if they haven't reclaimed it yet.
    /// Delete the flow to the beneficiary.
    /// Delete the flow from the renter to the app.
    function transitionToBiddingPhase() external whenNotPaused {
        if (isBiddingPhase) revert AlreadyInBiddingPhase();

        if (block.timestamp < currentPhaseEndTime) revert CurrentPhaseNotEnded();

        address _topBidder = topBidder;

        // return deposit (not reentrant)
        if (!depositClaimed) {
            acceptedToken.transfer(_topBidder, uint96(topFlowRate) * uint256(minRentalDuration)); 
        }

        // set state variables for beginning of bidding phase
        isBiddingPhase = true;
        depositClaimed = false;
        
        currentPhaseEndTime = 0;
        topFlowRate = 0;

        controllerObserver.onRenterChanged(_topBidder, address(0));

        // delete flow to beneficiary
        acceptedToken.deleteFlow(address(this), beneficiary);

        // delete the flow from the renter
        acceptedToken.deleteFlow(_topBidder, address(this));

        emit TransitionedToBiddingPhase();
    }

    /// @dev Called after a stream is created from the winning bidder. 
    /// Transition to the renting phase and create a stream to the beneficiary.
    /// Can technically be called whenever any stream is created to this app, but it will revert if this contract didn't initiate the stream.
    /// @param _ctx The Superfluid context
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
        if (host.decodeCtx(_ctx).msgSender != address(this)) revert Unauthorized();

        // stream sender must be the currentRenter and we are transitioning to the rental phase

        address _topBidder = topBidder;
        int96 _topFlowRate = topFlowRate;

        isBiddingPhase = false;

        currentPhaseEndTime = block.timestamp + maxRentalDuration;

        controllerObserver.onRenterChanged(address(0), _topBidder);

        newCtx = acceptedToken.createFlowWithCtx(beneficiary, _topFlowRate, _ctx);
        
        emit TransitionedToRentalPhase(_topBidder, _topFlowRate);
    }

    /// @dev Called after a stream to or from this app is terminated. 
    /// If the stream from the app to the beneficiary is terminated, reopen the stream.
    /// If the stream from the renter to the app is terminated, transition to the bidding phase (possibly taking some of their deposit).    
    /// Otherwise, do nothing.
    function afterAgreementTerminated(
        ISuperToken _superToken,
        address _agreementClass,
        bytes32, // _agreementId,
        bytes calldata _agreementData,
        bytes calldata, // _cbdata,
        bytes calldata _ctx
    ) external override onlyHost returns (bytes memory newCtx) {
        // According to the app basic law, we should never revert in a termination callback
        if (_superToken != acceptedToken || _agreementClass != address(cfa)) {
            return _ctx;
        }

        newCtx = _ctx;

        address _topBidder = topBidder;
        int96 _topFlowRate = topFlowRate;

        (address streamSender, address streamReceiver) = abi.decode(_agreementData, (address,address));

        if (streamReceiver == beneficiary) {
            // the beneficiary has closed the stream from here to them
            // we should just reopen the stream
            return acceptedToken.createFlowWithCtx(beneficiary, _topFlowRate, newCtx);
        }

        // if we are not in renting phase or msgSender is not currentRenter, then do nothing
        if (!isBiddingPhase && streamSender == _topBidder) {
            // the current renter has terminated their stream

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

            controllerObserver.onRenterChanged(_topBidder, address(0));

            // delete flow to beneficiary
            newCtx = acceptedToken.deleteFlowWithCtx(address(this), beneficiary, newCtx);

            emit TransitionedToBiddingPhaseEarly(_topBidder, _topFlowRate);
        }
    }

    /*******************************************************
     * 
     * RentalAuctionControllerObserver functions
     * 
     *******************************************************/

    /// @notice Pause the auction. Can only be called by the controller while in the bidding phase.
    /// @dev If there is some bidder, they will be refunded their deposit.
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

    /// @notice Unpause the auction. Can only be called by the controller.
    function unpause() external onlyController whenPaused {
        paused = false;

        emit Unpaused();
    }

    /*******************************************************
     * 
     * Private functions
     * 
     *******************************************************/

    /// @notice Place a bid. Sender should have approved this contract to spend acceptedToken and manage streams for them.
    /// @dev Will revert if it is not approved for SuperToken transfer.
    /// Will NOT revert if it is not authorized to manage flows, if `msgSender` wins the auction their deposit will be taken.
    /// @param msgSender The account that is bidding
    /// @param flowRate The flow rate to bid
    function _placeBid(address msgSender, int96 flowRate) private {
        // check that the flowRate is valid and higher than the last bid
        if (flowRate <= 0) revert InvalidFlowRate();
        if (!isBidHigher(flowRate, topFlowRate) || flowRate < reserveRate) revert FlowRateTooLow();
        if (msgSender == beneficiary) revert BeneficiaryCannotBid();
        if (host.isApp(ISuperApp(msgSender))) revert SuperAppCannotBid();

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

    /*******************************************************
     * 
     * View functions
     * 
     *******************************************************/

    /// @return The current renter. If the auction is in the bidding phase, this will return address(0).
    function currentRenter() external view returns (address) {
        return isBiddingPhase ? address(0) : topBidder;
    }

    /// @return `upper > lower * minimumBidFactor`
    /// @param upper The supposedly higher bid
    /// @param lower The supposedly lower bid
    function isBidHigher(int96 upper, int96 lower) public view returns (bool) {
        return uint256(uint96(upper)) > uint256(uint96(lower)) * minimumBidFactorWad / _wad;
    }

    /// @inheritdoc IRentalAuction
    function isJailed() external view override returns (bool) {
        return host.isAppJailed(this);
    }


    // starting state in rental phase:
    //     the renter is streaming to app
    //     there may be other incoming streams to the app
    //     app is streaming to beneficiary

    //     topBidder = renter
    //     topFlowRate = renter's flow rate
    //     paused = false
    //     depositClaimed = false
    //     currentPhaseEndTime = time at which rental expires and bidding can start again

    // ending state in rental phase:
    //     the renter is streaming to app
    //     there may be other incoming streams to the app
    //     app is streaming to beneficiary

    //     topBidder = renter
    //     topFlowRate = renter's flow rate
    //     paused = false
    //     depositClaimed = true or false
    //     currentPhaseEndTime = time at which rental expires and bidding can start again

    // starting state in bidding phase:
    //     app is NOT streaming to beneficiary
    //     there may be some incoming streams to the app (not in the normal case though)

    //     topBidder = undefined
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
}
