// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";


import { SuperAppBase } from "superfluid-finance/contracts/apps/SuperAppBase.sol";
import { SuperTokenV1Library } from "superfluid-finance/contracts/apps/SuperTokenV1Library.sol";
import { ISuperfluid, ISuperToken, SuperAppDefinitions } from "superfluid-finance/contracts/interfaces/superfluid/ISuperfluid.sol";
import { IConstantFlowAgreementV1 } from "superfluid-finance/contracts/interfaces/agreements/IConstantFlowAgreementV1.sol";

/// @dev Thrown when the callback caller is not the host.
error Unauthorized();

/// @dev Thrown when the token being streamed to this contract is invalid
error InvalidToken();

/// @dev Thrown when the agreement is other than the Constant Flow Agreement V1
error InvalidAgreement();

error FlowRateTooLow();
error FlowRateTooHigh();

error InvalidRight();

error Paused();
error NotPaused();

// TODO replace this everywhere
error Unknown();



/*

TODO:

rename ethereum-contracts gitmodule

constructor arg for IRentalAuctionControllerObserver (or IRentalAuctionEventHandler, IRentalAuctionHooks, IRentalAuctionController). A contract that gets called when a new winner is assigned (and can also cancel the auction)
    must be erc165 
supportsInterface

a func on RentalAuction called something like closeAuction(). 
    This function must have some type of access control. 
    It is used to stop the auction and redirect any streams back to senders. 
    now revert on afterAgreementCreated

    also have kickSender() - for giving senders time limits or rejecting them for whatever other reason

have a reserve rate, all streams must be >= this minumum

make a description field (link to ipfs)


make a new contract that has support for minimum rental times
    new contract works more like a traditional auction. 
    there is a period where people can bid (open stream + make deposit)
    renter can back out, but if they do so prematurely, a portion of their deposit gets taken
    renter (or owner) specifies the duration that they are guaranteed to rent the item for (unless they cancel)

    no linked list in this one, you either outbid the top bidder or don't bid at all
        when current top bidder is outbid, their deposit is returned to them

*/

interface IRentalAuctionControllerObserver {
    function onWinnerChanged(address newWinner) external;
}

contract RentalAuction is SuperAppBase {
    // SuperToken library setup
    using SuperTokenV1Library for ISuperToken;

    /// @dev Doubly linked list node for storing senders and their flow rates in ascending order
    /// @dev left is the node/sender to the left, right is right
    /// @dev if left = address(0), then it is the first item in the list
    /// @dev similarly, if right = address(0), then it is the last item in the list
    /// @dev no two senders can have equal flowRate
    /// @dev all items in the list have flowRate > 0. Any ListNodes with flowRate <= 0 are not in the list.
    struct SenderInfoListNode {
        int96 flowRate;
        address left;
        address right;

        address sender;
    }
    
    ISuperToken public immutable acceptedToken;
    ISuperfluid public immutable host;
    IConstantFlowAgreementV1 public immutable cfa;

    IRentalAuctionControllerObserver public immutable controllerObserver;

    address public immutable beneficiary;

    uint256 public immutable minimumBidFactorWad;
    uint256 constant _wad = 1e18;

    /// @dev mapping containing linked list of senders' flow rates in ascending order
    mapping(address => SenderInfoListNode) public senderInfo;

    /// @dev The sender of the stream with the highest flowrate. Marks right of linked list. When 0 there are now incoming streams
    address public topStreamer;

    /// @dev maps a sender to their user data. They provide this data when creating or updating a stream
    mapping(address => bytes) public senderUserData;

    bool public paused;

    int96 public immutable reserveRate;

    event NewTopStreamer(address indexed oldTopStreamer, address indexed newTopStreamer);
    event NewInboundStream(address indexed streamer, int96 flowRate);
    event StreamUpdated(address indexed streamer, int96 flowRate);
    event StreamTerminated(address indexed streamer);

    constructor(
        ISuperToken _acceptedToken,
        ISuperfluid _host,
        IConstantFlowAgreementV1 _cfa,
        IRentalAuctionControllerObserver _controllerObserver,
        address _beneficiary,
        uint96 _minimumBidFactorWad,
        int96 _reserveRate
    ) {
        require(address(_host) != address(0));
        require(address(_acceptedToken) != address(0));
        require(_beneficiary != address(0));

        require(_minimumBidFactorWad < uint256(type(uint160).max)); // prevent overflow
        require(_reserveRate >= 0);

        acceptedToken = _acceptedToken;
        
        host = _host;
        cfa = _cfa;

        controllerObserver = _controllerObserver;

        beneficiary = _beneficiary;
        minimumBidFactorWad = _minimumBidFactorWad;
        reserveRate = _reserveRate;

        // Registers Super App, indicating it is the final level (it cannot stream to other super
        // apps), and that the `before*` callbacks should not be called on this contract, only the
        // `after*` callbacks.
        host.registerApp(
            SuperAppDefinitions.APP_LEVEL_FINAL | // TODO: for now assume final, later figure out how to remove this requirement safely
                SuperAppDefinitions.BEFORE_AGREEMENT_CREATED_NOOP |
                SuperAppDefinitions.BEFORE_AGREEMENT_UPDATED_NOOP |
                SuperAppDefinitions.BEFORE_AGREEMENT_TERMINATED_NOOP
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
        if (paused) revert Paused();
        _;
    }

    modifier whenPaused() {
        if (!paused) revert NotPaused();
        _;
    }

    function afterAgreementCreated(
        ISuperToken _superToken,
        address _agreementClass,
        bytes32, //_agreementId
        bytes calldata, //_agreementData
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
        // it is not possible that stream sender already has a stream to this app

        newCtx = _ctx;

        ISuperfluid.Context memory decompiledContext = host.decodeCtx(_ctx);
        
        address streamSender = decompiledContext.msgSender;
        int96 inFlowRate = acceptedToken.getFlowRate(streamSender, address(this));

        if (inFlowRate < reserveRate) revert FlowRateTooLow();

        (address rightAddress, bytes memory userData) = abi.decode(decompiledContext.userData, (address, bytes));
        
        address oldTopStreamer = topStreamer;

        _insertSenderInfoListNode(inFlowRate, streamSender, rightAddress);

        senderUserData[streamSender] = userData;

        if (rightAddress == address(0)) {
            // this is the new top streamer

            if (oldTopStreamer == address(0)) {
                // this is the first stream
                // create flow to beneficiary
                newCtx = acceptedToken.createFlowWithCtx(beneficiary, inFlowRate, newCtx);
            }
            else {
                // update flow rate to beneficiary
                newCtx = acceptedToken.updateFlowWithCtx(beneficiary, inFlowRate, newCtx);
                // create stream to old top streamer
                newCtx = acceptedToken.createFlowWithCtx(oldTopStreamer, senderInfo[oldTopStreamer].flowRate, newCtx);
            }

            // notify controller
            if (address(controllerObserver) != address(0)) controllerObserver.onWinnerChanged(streamSender);

            // emit Event
            emit NewTopStreamer(oldTopStreamer, streamSender);
        }
        else {
            // this is not the top streamer

            // send a stream of equal rate back to sender
            newCtx = acceptedToken.createFlowWithCtx(streamSender, inFlowRate, newCtx);
        }

        emit NewInboundStream(streamSender, inFlowRate);
    }

    function afterAgreementUpdated(
        ISuperToken _superToken,
        address _agreementClass,
        bytes32, // _agreementId,
        bytes calldata, // _agreementData,
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

        ISuperfluid.Context memory decompiledContext = host.decodeCtx(_ctx);
        
        address streamSender = decompiledContext.msgSender;
        int96 inFlowRate = acceptedToken.getFlowRate(streamSender, address(this));

        if (inFlowRate < reserveRate) revert FlowRateTooLow();

        (address rightAddress, bytes memory userData) = abi.decode(decompiledContext.userData, (address, bytes));
        
        address oldTopStreamer = topStreamer;

        _updateSenderInfoListNode(inFlowRate, streamSender, rightAddress);

        senderUserData[streamSender] = userData;

        /*
        There are 3 scenarios:
        non top -> non top
            updateFlow to sender with new rate
        top -> non top
            createFlow to old top
            deleteFlow to new top
            updateFlow to beneficiary with new top flow
        non top -> top
            createFlow to old top
            deleteFlow to new top
            updateFlow to beneficiary with new top flow
        */
        
        if (oldTopStreamer != topStreamer) {
            // create flow to old top
            newCtx = acceptedToken.createFlowWithCtx(oldTopStreamer, senderInfo[oldTopStreamer].flowRate, newCtx);

            // delete flow to new top
            newCtx = acceptedToken.deleteFlowWithCtx(address(this), topStreamer, newCtx);

            // update flow to beneficiary
            int96 newTopRate = senderInfo[topStreamer].flowRate;
            newCtx = acceptedToken.updateFlowWithCtx(beneficiary, newTopRate, newCtx);

            // notify controller
            if (address(controllerObserver) != address(0)) controllerObserver.onWinnerChanged(topStreamer);

            emit NewTopStreamer(oldTopStreamer, topStreamer);
        }
        else {
            // update flow to sender
            newCtx = acceptedToken.updateFlowWithCtx(streamSender, inFlowRate, newCtx);
        }

        emit StreamUpdated(streamSender, inFlowRate);
    }

    function afterAgreementTerminated(
        ISuperToken _superToken,
        address _agreementClass,
        bytes32, // _agreementId,
        bytes calldata, // _agreementData
        bytes calldata, // _cbdata,
        bytes calldata _ctx
    ) external override onlyHost returns (bytes memory newCtx) {
        // According to the app basic law, we should never revert in a termination callback
        if (_superToken != acceptedToken || _agreementClass != address(cfa)) {
            return _ctx;
        }

        newCtx = _ctx;

        address streamSender = host.decodeCtx(newCtx).msgSender;

        address oldTopStreamer = topStreamer;

        // remove from linked list
        _removeSenderInfoListNode(streamSender);

        address newTopStreamer = topStreamer;

        if (newTopStreamer == address(0)) {
            // deleted stream was the top and there are now no incoming streams

            if (paused) {
                // if we're paused then there is no beneficiary stream
                // we have to delete return stream
                newCtx = acceptedToken.deleteFlowWithCtx(address(this), oldTopStreamer, newCtx);
            }
            else {
                // delete beneficiary stream
                newCtx = acceptedToken.deleteFlowWithCtx(address(this), beneficiary, newCtx);

                // notify controller
                if (address(controllerObserver) != address(0)) controllerObserver.onWinnerChanged(address(0));
            }

            emit NewTopStreamer(oldTopStreamer, address(0));
        }
        else if (oldTopStreamer != newTopStreamer) {
            // deleted stream was the top and a new top has been chosen

            if (paused) {
                // if we're paused then there is no beneficiary stream
                // we have to delete return stream
                newCtx = acceptedToken.deleteFlowWithCtx(address(this), oldTopStreamer, newCtx);
            }
            else {
                // remove return stream to new top
                newCtx = acceptedToken.deleteFlowWithCtx(address(this), newTopStreamer, newCtx);

                // update beneficiary stream
                newCtx = acceptedToken.updateFlowWithCtx(beneficiary, senderInfo[newTopStreamer].flowRate, newCtx);

                // notify controller
                if (address(controllerObserver) != address(0)) controllerObserver.onWinnerChanged(newTopStreamer);
            }

            emit NewTopStreamer(oldTopStreamer, newTopStreamer);
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

    function pause() external onlyController whenNotPaused {
        paused = true;
        address _topStreamer = topStreamer;

        if (_topStreamer != address(0)) {
            // delete beneficiary stream
            acceptedToken.deleteFlow(address(this), beneficiary);

            // we need to send a return stream to the top streamer
            acceptedToken.createFlow(_topStreamer, senderInfo[_topStreamer].flowRate);
        }
    }

    function unpause() external onlyController whenPaused {
        paused = false;

        address _topStreamer = topStreamer;

        if (_topStreamer != address(0)) {
            // we need to send a return stream to the top streamer
            acceptedToken.deleteFlow(address(this), _topStreamer);

            // we need to create flow to beneficiary
            acceptedToken.createFlow(_topStreamer, senderInfo[_topStreamer].flowRate);
        }
    }
    
    /*******************************************************
     * 
     * Linked List Operations
     * 
     *******************************************************/

    function isBidHigher(int96 upper, int96 lower) public view returns (bool) {
        return uint256(uint96(upper)) >= uint256(uint96(lower)) * minimumBidFactorWad / _wad;
    }

    // assumes that sender already exists in the list
    // TODO: newRate -> _newRate
    function _updateSenderInfoListNode(int96 newRate, address sender, address right) internal {
        SenderInfoListNode storage node = senderInfo[sender];
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
    }

    // assumes that sender exists in the list
    function _removeSenderInfoListNode(address sender) internal {
        SenderInfoListNode storage center = senderInfo[sender];

        if (center.left != address(0)) {
            senderInfo[center.left].right = center.right;
        }
        
        if (center.right != address(0)) {
            senderInfo[center.right].left = center.left;
        }
        else {
            // this is topStreamer
            require(sender == topStreamer, "TODO REMOVE DEBUG 1");
            topStreamer = center.left;
        }

        assembly {
            // center.flowRate = 0;
            // center.left = address(0);
            // center.right = address(0);
            sstore(center.slot, 0)
            sstore(add(center.slot, 1), 0)
        }
    }

    // assumes that newSender is not already in the list
    function _insertSenderInfoListNode(int96 newRate, address newSender, address right) internal {
        address left;
        if (right == address(0)) {
            left = topStreamer;

            topStreamer = newSender;
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


        // TODO: assembly
        SenderInfoListNode storage newNode = senderInfo[newSender];
        newNode.left = left;
        newNode.right = right;
        newNode.sender = newSender;
        newNode.flowRate = newRate;
    }
}
