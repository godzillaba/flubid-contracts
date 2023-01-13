// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

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

error PosTooHigh();
error PosTooLow();
// TODO replace this everywhere
error Unknown();



/*

TODO:

constructor arg for IRentalAuctionControllerObserver (or IRentalAuctionEventHandler, IRentalAuctionHooks, IRentalAuctionController). A contract that gets called when a new winner is assigned (and can also cancel the auction)
    must be erc165 
supportsInterface

a func on RentalAuction called something like closeAuction(). 
    This function must have some type of access control. 
    It is used to stop the auction and redirect any streams back to senders. 
    now revert on afterAgreementCreated

*/

contract RentalAuction is SuperAppBase {
    // SuperToken library setup
    using SuperTokenV1Library for ISuperToken;
    
    ISuperToken public immutable acceptedToken;
    ISuperfluid public immutable host;
    IConstantFlowAgreementV1 public immutable cfa;

    address public receiver;

    /// @dev Linked list node
    /// @dev each node is looked up by sender
    /// @dev left is the node/sender to the left, right is right
    /// @dev if left = address(0), then it is the first item in the list
    /// @dev similarly, if right = address(0), then it is the last item in the list
    struct SenderInfoListNode { // TODO: rename this to something like SenderInfo or SenderInfoListNode
        address left;
        address right;

        address sender;
        int96 flowRate;
    }

    mapping(address => SenderInfoListNode) public senderInfo;

    // TODO: mapping address to bytes (bytes is a user defined message passed when creating/updating a stream)

    /// @dev The sender of the stream with the highest flowrate. When 0 there are now incoming streams
    address public topStreamer;

    constructor(
        ISuperToken _acceptedToken,
        ISuperfluid _host,
        IConstantFlowAgreementV1 _cfa,
        address _receiver
    ) {
        require(address(_host) != address(0));
        require(address(_acceptedToken) != address(0));
        require(_receiver != address(0));

        acceptedToken = _acceptedToken;
        receiver = _receiver;
        host = _host;
        cfa = _cfa;


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

    // assumes that sender already exists in the list
    function _updateSenderInfoListNode(int96 newRate, address sender, address right) internal {
        SenderInfoListNode storage node = senderInfo[sender];
        address left = node.left;
        
        if (right == node.right) {
            if (left != address(0) && newRate <= senderInfo[node.left].flowRate) revert PosTooHigh();
            if (right != address(0) && newRate >= senderInfo[right].flowRate) revert PosTooLow();

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

        center.left = address(0);
        center.right = address(0);
    }

    // TODO: maybe put this stuff in abstract contract? would be better for testing OR just make it internal, derive a test contract from this one
    // newRate cannot be equal to any other incoming stream. must be strictly less than right and strictly more than left
    // assumes that newSender is not already in the list
    function _insertSenderInfoListNode(int96 newRate, address newSender, address right) internal {
        address left;
        if (right == address(0)) {
            left = topStreamer;

            topStreamer = newSender;
        }
        else {
            left = senderInfo[right].left;
        }

        if (right != address(0)) {
            // make sure inFlowRate is less than rightFlowRate
            if (newRate >= senderInfo[right].flowRate) revert PosTooLow();

            senderInfo[right].left = newSender;
        }

        if (left != address(0)) {
            // make sure inFlowRate is greater than rightFlowRate
            if (newRate <= senderInfo[left].flowRate) revert PosTooHigh();

            senderInfo[left].right = newSender;
        }

        SenderInfoListNode storage newNode = senderInfo[newSender];
        newNode.left = left;
        newNode.right = right;
        newNode.sender = newSender;
        newNode.flowRate = newRate;
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
        returns (bytes memory newCtx)
    {
        // insert into linked list
        // update winner and previous winner streams
        // if position in linked list is missing or incorrect, revert
        newCtx = _ctx;

        ISuperfluid.Context memory decompiledContext = host.decodeCtx(_ctx);
        
        address streamSender = decompiledContext.msgSender;
        int96 inFlowRate = acceptedToken.getFlowRate(streamSender, address(this));

        address rightAddress = abi.decode(decompiledContext.userData, (address));
        
        // _insertSenderInfoListNode(inFlowRate, streamSender, rightAddress);

        


        
        // if (rightAddress == address(0)) {
        //     if (inFlowRate <= senderInfo[topStreamer].flowRate) revert Unknown(); // incorrect position, new flow rate is less than the one to the left

        //     // this is indeed the new winner

        //     // we need to redirect old winner back to itself
            
        //     // insert at the end of linked list
        //     senderInfo[topStreamer].right = streamSender;

        //     LinkedListNode memory lln = senderInfo[streamSender];
        //     lln.left = topStreamer;
        //     lln.right = address(0);
        //     lln.sender = streamSender;
        //     lln.flowRate = inFlowRate;
        // }
        // else {

        //     if (inFlowRate >= senderInfo[rightAddress].flowRate) revert Unknown(); // not correct position, new flow rate is higher than the one to the right

        //     address leftAddress = linke
        // }
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
        returns (bytes memory newCtx)
    {
        // remove from linked list
        // insert into linked list
        // update winner and previous winner streams
        // if position in linked list is missing or incorrect, revert
        newCtx = _ctx;
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

        // remove from linked list
        // update winner and previous winner streams
        // CANNOT REVERT HERE
        newCtx = _ctx;
    }
}
