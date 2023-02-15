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

contract ContinuousRentalAuction is SuperAppBase, Initializable, IRentalAuction {
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
    
    ISuperToken public acceptedToken;
    ISuperfluid public host;
    IConstantFlowAgreementV1 public cfa;

    IRentalAuctionControllerObserver public controllerObserver;

    address public beneficiary;

    uint256 public minimumBidFactorWad;
    uint256 constant _wad = 1e18;

    /// @dev mapping containing linked list of senders' flow rates in ascending order
    mapping(address => SenderInfoListNode) public senderInfo;

    /// @dev The sender of the stream with the highest flowrate. Marks right of linked list. When 0 there are now incoming streams
    address public currentRenter;

    /// @dev maps a sender to their user data. They provide this data when creating or updating a stream
    mapping(address => bytes) public senderUserData;

    bool public paused;

    int96 public reserveRate;

    event Initialized(
        address indexed acceptedToken, 
        address indexed controllerObserver, 
        address indexed beneficiary,
        uint96 minimumBidFactorWad,
        int96 reserveRate
    );

    event RenterChanged(address indexed oldRenter, address indexed newRenter);
    event NewInboundStream(address indexed streamer, int96 flowRate);
    event StreamUpdated(address indexed streamer, int96 flowRate);
    event StreamTerminated(address indexed streamer);

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

        require(_minimumBidFactorWad < uint256(type(uint160).max)); // prevent overflow (TODO: why is this here it makes no sense)
        require(_minimumBidFactorWad >= _wad);
        require(_reserveRate >= 0);

        acceptedToken = _acceptedToken;
        
        host = _host;
        cfa = _cfa;

        controllerObserver = _controllerObserver;

        beneficiary = _beneficiary;
        minimumBidFactorWad = _minimumBidFactorWad;
        reserveRate = _reserveRate;
        
        emit Initialized(address(_acceptedToken), address(_controllerObserver), _beneficiary, _minimumBidFactorWad, _reserveRate);
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
        
        address streamSender = decompiledContext.msgSender; // todo: this assumes that acl isn't a thing, fix it to be actual stream sender. also prevent beneficiary from streaming to this app, can cause weirdness when paused i think
        int96 inFlowRate = acceptedToken.getFlowRate(streamSender, address(this));

        if (inFlowRate < reserveRate) revert FlowRateTooLow();

        (address rightAddress, bytes memory userData) = abi.decode(decompiledContext.userData, (address, bytes));
        
        address oldRenter = currentRenter;

        _insertSenderInfoListNode(inFlowRate, streamSender, rightAddress);

        senderUserData[streamSender] = userData;

        if (rightAddress == address(0)) {
            // this is the new top streamer

            if (oldRenter == address(0)) {
                // this is the first stream
                // create flow to beneficiary
                newCtx = acceptedToken.createFlowWithCtx(beneficiary, inFlowRate, newCtx);
            }
            else {
                // update flow rate to beneficiary
                newCtx = acceptedToken.updateFlowWithCtx(beneficiary, inFlowRate, newCtx);
                // create stream to old top streamer
                newCtx = acceptedToken.createFlowWithCtx(oldRenter, senderInfo[oldRenter].flowRate, newCtx);
            }

            // notify controller
            if (address(controllerObserver) != address(0)) controllerObserver.onRenterChanged(streamSender);

            // emit Event
            emit RenterChanged(oldRenter, streamSender);
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
        
        address streamSender = decompiledContext.msgSender; // todo: don't use this as streamSender, use agreementData
        int96 inFlowRate = acceptedToken.getFlowRate(streamSender, address(this));

        if (inFlowRate < reserveRate) revert FlowRateTooLow();

        (address rightAddress, bytes memory userData) = abi.decode(decompiledContext.userData, (address, bytes));
        
        address oldRenter = currentRenter;

        _updateSenderInfoListNode(inFlowRate, streamSender, rightAddress);

        senderUserData[streamSender] = userData;

        /*
        There are 4 scenarios:
        1. top -> top
            updateFlow to beneficiary with new rate
        2. non top -> non top
            updateFlow to sender with new rate
        3. top -> non top
            createFlow to old top
            deleteFlow to new top
            updateFlow to beneficiary with new top flow
        4. non top -> top
            createFlow to old top
            deleteFlow to new top
            updateFlow to beneficiary with new top flow
        */
        
        // scenario 3 and 4 are the same
        if (oldRenter != currentRenter) {
            // create flow to old top
            newCtx = acceptedToken.createFlowWithCtx(oldRenter, senderInfo[oldRenter].flowRate, newCtx);

            // delete flow to new top
            // todo: test if it is possible for this to be already deleted by the bidder
            newCtx = acceptedToken.deleteFlowWithCtx(address(this), currentRenter, newCtx);

            // update flow to beneficiary
            int96 newTopRate = senderInfo[currentRenter].flowRate;
            newCtx = acceptedToken.updateFlowWithCtx(beneficiary, newTopRate, newCtx);

            // notify controller
            if (address(controllerObserver) != address(0)) controllerObserver.onRenterChanged(currentRenter);

            emit RenterChanged(oldRenter, currentRenter);
        }
        // scenario 1 (oldRenter == currentRenter here)
        else if (streamSender == oldRenter) {
            newCtx = acceptedToken.updateFlowWithCtx(beneficiary, inFlowRate, newCtx);
        } 
        // scenario 2
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

        address oldRenter = currentRenter;

        // remove from linked list
        _removeSenderInfoListNode(streamSender);

        address newTopStreamer = currentRenter;

        if (newTopStreamer == address(0)) {
            // deleted stream was the top and there are now no incoming streams

            if (paused) {
                // if we're paused then there is no beneficiary stream
                // we have to delete return stream
                newCtx = acceptedToken.deleteFlowWithCtx(address(this), oldRenter, newCtx);
            }
            else {
                // delete beneficiary stream
                newCtx = acceptedToken.deleteFlowWithCtx(address(this), beneficiary, newCtx);

                // notify controller
                if (address(controllerObserver) != address(0)) controllerObserver.onRenterChanged(address(0));
            }

            emit RenterChanged(oldRenter, address(0));
        }
        else if (oldRenter != newTopStreamer) {
            // deleted stream was the top and a new top has been chosen

            if (paused) {
                // if we're paused then there is no beneficiary stream
                // we have to delete return stream
                newCtx = acceptedToken.deleteFlowWithCtx(address(this), oldRenter, newCtx);
            }
            else {
                // remove return stream to new top
                newCtx = acceptedToken.deleteFlowWithCtx(address(this), newTopStreamer, newCtx);

                // update beneficiary stream
                newCtx = acceptedToken.updateFlowWithCtx(beneficiary, senderInfo[newTopStreamer].flowRate, newCtx);

                // notify controller
                if (address(controllerObserver) != address(0)) controllerObserver.onRenterChanged(newTopStreamer);
            }

            emit RenterChanged(oldRenter, newTopStreamer);
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
        address _topStreamer = currentRenter;

        if (_topStreamer != address(0)) {
            // delete beneficiary stream
            acceptedToken.deleteFlow(address(this), beneficiary);

            // we need to send a return stream to the top streamer
            acceptedToken.createFlow(_topStreamer, senderInfo[_topStreamer].flowRate);
        }
    }

    function unpause() external onlyController whenPaused {
        paused = false;

        address _topStreamer = currentRenter;

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
        return uint256(uint96(upper)) > uint256(uint96(lower)) * minimumBidFactorWad / _wad;
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
            // this is currentRenter
            require(sender == currentRenter, "TODO REMOVE DEBUG 1");
            currentRenter = center.left;
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
            left = currentRenter;

            currentRenter = newSender;
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
