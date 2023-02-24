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

/// @title ContinuousRentalAuction

/// @notice A continuous rental auction contract that uses Superfluid streams to accept bids.
/// While the auction is active, the contract accepts incoming streams of the accepted token as "bids".
/// The contract keeps a doubly linked list of senders and their flow rates in ascending order.
/// Whoever has the highest flow rate is the current renter. 
/// Everyone else with a smaller flow rate has a stream of equal rate sent back to them.
/// Bidders can create, update or delete streams at any time to change their bid.

/// @dev The state must always be consistent. Consistent state means: 
/// The linked list is sorted in ascending order by flow rate.
/// There is an inbound stream from `sender` of `flowRate` for every `SenderInfoListNode` in the linked list. 
/// There is not an inbound stream from the beneficiary.
/// When the auction is paused: 
///   All inbound streams have a matching outbound stream to the sender.
///   There is no stream to the beneficiary.
/// When the auction is not paused: 
///   All senders must have a matching return stream except the top sender. 
///   There must be no return stream to the top sender. 
///   There must be a stream to the beneficiary matching the top sender's flow rate.
contract ContinuousRentalAuction is SuperAppBase, Initializable, IRentalAuction {
    // SuperToken library setup
    using SuperTokenV1Library for ISuperToken;

    /// @notice A node in the sorted doubly linked list of senders and their flow rates
    /// @dev If `left == address(0)`, then it is the first item in the list.
    /// Similarly, if `right == address(0)`, then it is the last item in the list
    /// No two senders can have equal `flowRate`.
    /// All items in the list have `flowRate > 0`. Any `SenderInfoListNode` with `flowRate <= 0` is not in the list.
    /// @param flowRate The flow rate of the sender
    /// @param left The sender to the left of this sender in the linked list
    /// @param right The sender to the right of this sender in the linked list
    /// @param sender The address of the sender
    struct SenderInfoListNode {
        int96 flowRate;
        address left;
        address right;
        address sender;
    }
    
    /*******************************************************
     * 
     * Constant State Variables
     * 
     *******************************************************/

    /// @dev Wad constant
    uint256 constant _wad = 1e18;

    /// @notice The accepted token of the auction
    ISuperToken public acceptedToken;

    /// @notice The Superfluid host
    ISuperfluid public host;
    /// @notice The Superfluid CFA Contract
    IConstantFlowAgreementV1 public cfa;

    /// @notice The controller observer contract
    IRentalAuctionControllerObserver public controllerObserver;

    /// @notice The minimum bid factor (wad). When placing a bid, it must be at least this factor times the next highest bid.
    uint96 public minimumBidFactorWad;

    /// @notice The address of the auction beneficiary. They receive the proceeds of the auction.
    address public beneficiary;

    /// @notice The reserve rate. The auction will not accept streams with a flow rate lower than this.
    int96 public reserveRate;

    /*******************************************************
     * 
     * Non-constant State Variables
     * 
     *******************************************************/

    /// @notice Each sender's `SenderInfoListNode` in the linked list
    mapping(address => SenderInfoListNode) public senderInfo;

    /// @notice The sender of the stream with the highest flowrate. 
    /// Marks right of linked list. When 0 there are no incoming streams.
    address public topSender;

    /// @notice Whether the auction is paused
    bool public paused;

    /*******************************************************
     * 
     * Events
     * 
     *******************************************************/

    /// @notice Emitted when the renter changes
    /// @param oldRenter The previous renter
    /// @param newRenter The new renter
    event RenterChanged(address indexed oldRenter, address indexed newRenter);

    /// @notice Emitted when a new stream is sent to this contract
    /// @param sender The address of the sender
    /// @param flowRate The flow rate of the stream
    event NewInboundStream(address indexed sender, int96 flowRate);

    /// @notice Emitted when an inbound stream is updated
    /// @param sender The address of the sender
    /// @param flowRate The new flow rate of the stream
    event StreamUpdated(address indexed sender, int96 flowRate);

    /// @notice Emitted when an inbound stream is terminated
    /// @param sender The address of the sender
    event StreamTerminated(address indexed sender);

    /// @notice Emitted when the auction is paused
    event Paused();
    
    /// @notice Emitted when the auction is unpaused
    event Unpaused();

    /*******************************************************
     * 
     * Errors
     * 
     *******************************************************/

    /// @notice Error indicating that a SuperApp callback was called from an address other than the Superfluid host.
    error Unauthorized();

    /// @notice Thrown when the token being streamed into this app is not the accepted token.
    error InvalidToken();

    /// @notice Thrown when the agreement is other than the Constant Flow Agreement V1
    error InvalidAgreement();

    /// @notice Error indicating that the flow rate is too low.
    /// @dev Thrown if the linked list position provided is incorrect.
    /// Thrown if the flow rate is lower than the reserve rate.
    /// Thrown if the linked list position is correct, but the flow rate is lower than the minimum bid factor times the flow rate to the left.
    error FlowRateTooLow();

    /// @notice Error indicating that the flow rate is too low.
    /// @dev Thrown if the linked list position provided is incorrect.
    error FlowRateTooHigh();

    /// @notice Error indicating that the provided linked list position points to an invalid node.
    error InvalidRight();

    /// @notice Error indicating that the auction is paused.
    error IsPaused();
    /// @notice Error indicating that the auction is not paused.
    error IsNotPaused();

    /// @notice Thrown when the beneficiary tries to bid.
    error BeneficiaryCannotBid();

    /// @notice Thrown when a sender who is not in the linked list tries to update their stream to this app.
    /// @dev This could happen if a sender sends a stream to this address before the auction is deployed.
    error SenderNotInList();

    /// @notice SuperApps are not allowed to bid
    error SuperAppCannotBid();

    /*******************************************************
     * 
     * Initialization
     * 
     *******************************************************/

    /// @notice Initializes the auction contract
    /// @param _acceptedToken The accepted token of the auction
    /// @param _host The Superfluid host
    /// @param _cfa The Superfluid CFA Contract
    /// @param _controllerObserver The controller observer contract
    /// @param _beneficiary The address of the auction beneficiary. They receive the proceeds of the auction.
    /// @param _minimumBidFactorWad The minimum bid factor (wad). When placing a bid, it must be at least this factor times the next highest bid.
    /// @param _reserveRate The reserve rate. The auction will not accept streams with a flow rate lower than this.
    function initialize(
        ISuperToken _acceptedToken,
        ISuperfluid _host,
        IConstantFlowAgreementV1 _cfa,
        IRentalAuctionControllerObserver _controllerObserver,
        address _beneficiary,
        uint96 _minimumBidFactorWad,
        int96 _reserveRate
    ) external initializer {
        require(address(_host) != address(0));
        require(address(_acceptedToken) != address(0));
        require(_beneficiary != address(0));

        // the minimum bid factor must be at least 1
        require(_minimumBidFactorWad >= _wad);

        // the reserve rate cannot be negative
        require(_reserveRate >= 0);

        acceptedToken = _acceptedToken;
        
        host = _host;
        cfa = _cfa;

        controllerObserver = _controllerObserver;

        beneficiary = _beneficiary;
        minimumBidFactorWad = _minimumBidFactorWad;
        reserveRate = _reserveRate;

        // start the auction off paused
        paused = true;
    }

    /*******************************************************
     * 
     * Modifiers
     * 
     *******************************************************/

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

    /*******************************************************
     * 
     * SuperApp callbacks
     * 
     *******************************************************/

    /// @notice Called by the Superfluid host after a stream to this contract is created.
    /// @dev This function will place the sender in the linked list assuming the basic requirements are met.
    /// The flow sender must include the correct linked list position 
    /// (sender to their right, or 0 if they are the highest) in the userData when creating the stream.
    /// If the sender is not the highest bidder, a flow of equal rate will be sent back to them.
    /// If the sender is the highest bidder:
    /// 1. The flow to the beneficiary will be updated to be of equal rate.
    /// 2. A flow will be created to the previous highest bidder if there is one.
    /// 3. The controller will be notified of the new renter via `onRenterChanged`.
    /// @param _superToken The SuperToken being streamed
    /// @param _agreementClass The agreement class of the stream
    /// @param _agreementData The agreement data of the stream
    /// @param _ctx The Superfluid context
    /// @return newCtx The new Superfluid context
    function afterAgreementCreated(
        ISuperToken _superToken,
        address _agreementClass,
        bytes32, //_agreementId
        bytes calldata _agreementData,
        bytes calldata, //_cbdata
        bytes calldata _ctx
    )
        external
        override
        onlyExpected(_superToken, _agreementClass)
        onlyHost
        whenNotPaused
        returns (bytes memory newCtx)
    {
        // we have to keep track of context in SuperApp callbacks
        newCtx = _ctx;
        
        // decode the agreement data to get the sender
        (address streamSender,) = abi.decode(_agreementData, (address,address));

        // the beneficiary is not allowed to bid
        address _beneficiary = beneficiary;
        if (streamSender == _beneficiary) revert BeneficiaryCannotBid();

        // super apps cannot bid
        if (host.isApp(ISuperApp(streamSender))) revert SuperAppCannotBid();

        // get the flow rate
        int96 inFlowRate = acceptedToken.getFlowRate(streamSender, address(this));

        // make sure the flow rate is at least the reserve rate
        if (inFlowRate < reserveRate) revert FlowRateTooLow();

        // decode the userData to get the linked list position
        (address rightAddress) = abi.decode(host.decodeCtx(_ctx).userData, (address));
        
        // keep track of the old renter before we update the linked list
        address oldTopSender = topSender;

        // update the linked list
        _insertSenderInfoListNode(inFlowRate, streamSender, rightAddress);

        // if rightAddress is 0, this is the new top sender
        if (rightAddress == address(0)) {
            if (oldTopSender == address(0)) {
                // this is the first stream
                // create flow to beneficiary
                newCtx = acceptedToken.createFlowWithCtx(_beneficiary, inFlowRate, newCtx);
            }
            else {
                // update flow rate to beneficiary
                newCtx = acceptedToken.updateFlowWithCtx(_beneficiary, inFlowRate, newCtx);
                // create stream to old top sender
                newCtx = acceptedToken.createFlowWithCtx(oldTopSender, senderInfo[oldTopSender].flowRate, newCtx);
            }

            // notify controller
            controllerObserver.onRenterChanged(streamSender);

            emit RenterChanged(oldTopSender, streamSender);
        }
        else {
            // this is not the top sender

            // send a stream of equal rate back to sender
            newCtx = acceptedToken.createFlowWithCtx(streamSender, inFlowRate, newCtx);
        }

        emit NewInboundStream(streamSender, inFlowRate);
    }

    /// @notice Called by the Superfluid host after a stream to this contract is updated.
    /// @dev This function will update the sender in the linked list assuming the basic requirements are met.
    /// The flow sender must include the correct linked list position
    /// (sender to their right, or 0 if they are the highest) in the userData when updating the stream.
    /// There are three cases of the sender's position in the linked list:
    /// 1. `top -> top`: update the flow rate to the beneficiary with new rate
    /// 2. `not top -> not top`: update the flow rate to the sender with new rate
    /// 3. `not top -> top` or `top -> not top`: create flow to previous top, create flow to new top, update flow to beneficiary
    /// @param _superToken The SuperToken being streamed
    /// @param _agreementClass The agreement class of the stream
    /// @param _agreementData The agreement data of the stream
    /// @param _ctx The Superfluid context
    /// @return newCtx The new Superfluid context
    function afterAgreementUpdated(
        ISuperToken _superToken,
        address _agreementClass,
        bytes32, // _agreementId,
        bytes calldata _agreementData,
        bytes calldata, // _cbdata,
        bytes calldata _ctx
    )
        external
        override
        onlyExpected(_superToken, _agreementClass)
        onlyHost
        whenNotPaused
        returns (bytes memory newCtx)
    {
        // it is not possible that stream sender does not already has a stream to this app

        newCtx = _ctx;
        
        (address streamSender,) = abi.decode(_agreementData, (address,address));
        int96 inFlowRate = acceptedToken.getFlowRate(streamSender, address(this));

        if (inFlowRate < reserveRate) revert FlowRateTooLow();

        (address rightAddress) = abi.decode(host.decodeCtx(_ctx).userData, (address));
        
        address oldTopSender = topSender;

        // update linked list
        // if the sender is not in the list, revert. This can happen if the sender created the flow before the app was deployed
        if (!_updateSenderInfoListNode(inFlowRate, streamSender, rightAddress)) revert SenderNotInList();

        address newTopSender = topSender;
        
        // scenario 3
        if (oldTopSender != newTopSender) {
            // create flow to old top
            newCtx = acceptedToken.createFlowWithCtx(oldTopSender, senderInfo[oldTopSender].flowRate, newCtx);

            // delete flow to new top
            newCtx = acceptedToken.deleteFlowWithCtx(address(this), newTopSender, newCtx);

            // update flow to beneficiary
            int96 newTopRate = senderInfo[newTopSender].flowRate;
            newCtx = acceptedToken.updateFlowWithCtx(beneficiary, newTopRate, newCtx);

            // notify controller
            controllerObserver.onRenterChanged(newTopSender);

            emit RenterChanged(oldTopSender, newTopSender);
        }
        // scenario 1 (oldTopSender == topSender here)
        else if (streamSender == oldTopSender) {
            // update flow to beneficiary
            newCtx = acceptedToken.updateFlowWithCtx(beneficiary, inFlowRate, newCtx);
        } 
        // scenario 2
        else {
            // update flow to sender
            newCtx = acceptedToken.updateFlowWithCtx(streamSender, inFlowRate, newCtx);
        }

        emit StreamUpdated(streamSender, inFlowRate);
    }

    /// @notice Called by the Superfluid host when a stream a stream to or from this contract is terminated by someone other than this contract.
    /// @dev This function cannot revert per Superfluid's requirements.
    /// There are three scenarios:
    /// 1. The beneficiary deleted the stream from this app: Pause the auction and create a return flow to the top sender.
    /// 2. A bidder deleted the return stream from this app: Remove the sender from the linked list and delete the inbound flow from the bidder.
    /// 3. A bidder deleted their stream to this app: Remove the sender from the linked list. Modify streams accordingly.
    /// @param _superToken The SuperToken being streamed
    /// @param _agreementClass The agreement class of the stream
    /// @param _agreementData The agreement data of the stream
    /// @param _ctx The Superfluid context
    /// @return newCtx The new Superfluid context
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

        // keep track of context in SuperApp callbacks
        newCtx = _ctx;
        // decode agreement data to get stream sender and receiver
        (address streamSender, address streamReceiver) = abi.decode(_agreementData, (address,address));

        if (streamSender == address(this) && streamReceiver == beneficiary) {
            // the beneficiary has cancelled the stream from the app
            // we should just reopen it

            // if there is a stream to the beneficiary, there must be a stream from the top sender
            return acceptedToken.createFlowWithCtx(beneficiary, senderInfo[topSender].flowRate, newCtx);
        }
        else if (streamSender == address(this)) {
            // some bidder has terminated their return stream
            // we should just reopen it
            return acceptedToken.createFlowWithCtx(streamReceiver, senderInfo[streamReceiver].flowRate, newCtx);
        }

        address oldTopSender = topSender;

        // remove from linked list
        // if the sender is not in the list, do nothing. This can happen if the sender created the flow before the app was deployed
        if (!_removeSenderInfoListNode(streamSender)) return newCtx;

        address newTopSender = topSender;

        if (newTopSender == address(0)) {
            // deleted stream was the top and there are now no incoming streams

            if (paused) {
                // if we're paused then there is no beneficiary stream
                // we have to delete return stream
                newCtx = acceptedToken.deleteFlowWithCtx(address(this), oldTopSender, newCtx);
            }
            else {
                // delete beneficiary stream
                newCtx = acceptedToken.deleteFlowWithCtx(address(this), beneficiary, newCtx);

                // notify controller
                controllerObserver.onRenterChanged(address(0));
            }

            emit RenterChanged(oldTopSender, address(0));
        }
        else if (oldTopSender != newTopSender) {
            // deleted stream was the top and a new top has been chosen

            if (paused) {
                // if we're paused then there is no beneficiary stream
                // we have to delete return stream
                newCtx = acceptedToken.deleteFlowWithCtx(address(this), oldTopSender, newCtx);
            }
            else {
                // remove return stream to new top
                newCtx = acceptedToken.deleteFlowWithCtx(address(this), newTopSender, newCtx);

                // update beneficiary stream
                newCtx = acceptedToken.updateFlowWithCtx(beneficiary, senderInfo[newTopSender].flowRate, newCtx);

                // notify controller
                controllerObserver.onRenterChanged(newTopSender);
            }

            emit RenterChanged(oldTopSender, newTopSender);
        }
        else {
            // deleted stream was not the top
            // delete return stream
            newCtx = acceptedToken.deleteFlowWithCtx(address(this), streamSender, newCtx);
        }


        emit StreamTerminated(streamSender);
    }

    /*******************************************************
     * 
     * RentalAuctionControllerObserver functions
     * 
     *******************************************************/

    /// @notice Called by the controller to pause the auction
    /// @dev If there are any inbound streams, delete the beneficiary stream and create a return stream to the top sender.
    function pause() external onlyController whenNotPaused {
        paused = true;
        address _topSender = topSender;

        if (_topSender != address(0)) {
            // delete beneficiary stream
            acceptedToken.deleteFlow(address(this), beneficiary);

            // we need to send a return stream to the top sender
            acceptedToken.createFlow(_topSender, senderInfo[_topSender].flowRate);

            // notify controller
            controllerObserver.onRenterChanged(address(0));
        }

        emit Paused();
    }

    /// @notice Called by the controller to unpause the auction
    /// @dev If there are any inbound streams, delete the return stream to the top sender and create a beneficiary stream.
    function unpause() external onlyController whenPaused {
        paused = false;

        address _topSender = topSender;

        if (_topSender != address(0)) {
            // we need to delete the return stream to the top sender
            acceptedToken.deleteFlow(address(this), _topSender);

            // we need to create flow to beneficiary
            acceptedToken.createFlow(_topSender, senderInfo[_topSender].flowRate);

            // notify controller
            controllerObserver.onRenterChanged(_topSender);
        }

        emit Unpaused();
    }
    
    /*******************************************************
     * 
     * Linked List Operations
     * 
     *******************************************************/

    /// @notice Updates/moves an existing node in the linked list
    /// @param newRate The new flow rate
    /// @param sender The sender address
    /// @param right The address of the sender to the right of where the node should move to
    /// @return False if the node does not exist in the list, true otherwise
    function _updateSenderInfoListNode(int96 newRate, address sender, address right) internal returns (bool) {
        SenderInfoListNode storage node = senderInfo[sender];

        if (node.flowRate == 0) return false;

        address left = node.left;
        
        if (right == node.right) {
            if (left != address(0) && !isBidHigher(newRate, senderInfo[node.left].flowRate)) revert FlowRateTooLow();
            if (right != address(0) && newRate >= senderInfo[node.right].flowRate) revert FlowRateTooHigh();

            node.flowRate = newRate;
        }
        else {
            _removeSenderInfoListNode(sender);
            _insertSenderInfoListNode(newRate, sender, right);
        }

        return true;
    }

    /// @notice Removes a node from the linked list
    /// @param sender The sender address
    /// @return False if the node does not exist in the list, true otherwise
    function _removeSenderInfoListNode(address sender) internal returns (bool) {
        SenderInfoListNode storage center = senderInfo[sender];

        if (center.flowRate == 0) return false;

        if (center.left != address(0)) {
            senderInfo[center.left].right = center.right;
        }
        
        if (center.right != address(0)) {
            senderInfo[center.right].left = center.left;
        }
        else {
            // this is topSender
            topSender = center.left;
        }

        assembly {
            // center.flowRate = 0;
            // center.left = address(0);
            // center.right = address(0);
            sstore(center.slot, 0)
            sstore(add(center.slot, 1), 0)
        }

        return true;
    }

    /// @notice Inserts a new node into the linked list
    /// @dev This function assumes that the node does not exist in the list
    /// @param newRate The new flow rate
    /// @param newSender The sender address
    /// @param right The address of the sender to the right of where the node should be inserted
    function _insertSenderInfoListNode(int96 newRate, address newSender, address right) internal {
        address left;
        if (right == address(0)) {
            left = topSender;

            topSender = newSender;
        }
        else {
            SenderInfoListNode storage rightNode = senderInfo[right];
            
            if (rightNode.flowRate == 0) revert InvalidRight();

            left = rightNode.left;

            // make sure right flowRight is greater than inFlowRate
            if (newRate >= rightNode.flowRate) revert FlowRateTooHigh();

            rightNode.left = newSender;
        }

        if (left != address(0)) {
            SenderInfoListNode storage leftNode = senderInfo[left];
            // make sure inFlowRate is greater than leftFlowRate times minBidFactor
            if (!isBidHigher(newRate, leftNode.flowRate)) revert FlowRateTooLow();

            leftNode.right = newSender;
        }

        SenderInfoListNode storage newNode = senderInfo[newSender];
        newNode.left = left;
        newNode.right = right;
        newNode.sender = newSender;
        newNode.flowRate = newRate;
    }

    /*******************************************************
     * 
     * View functions
     * 
     *******************************************************/

    /// @return The address of the current renter
    /// @dev Returns 0 if the auction is paused
    function currentRenter() external view returns (address) {
        return paused ? address(0) : topSender;
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
}
