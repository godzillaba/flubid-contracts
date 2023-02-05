// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import {ISuperfluid, SuperAppDefinitions} from "superfluid-finance/contracts/interfaces/superfluid/ISuperfluid.sol";

import {ISuperToken} from "superfluid-finance/contracts/interfaces/superfluid/ISuperToken.sol";
import {ISuperTokenFactory} from "superfluid-finance/contracts/interfaces/superfluid/ISuperTokenFactory.sol";
import {IConstantFlowAgreementV1} from "superfluid-finance/contracts/interfaces/agreements/IConstantFlowAgreementV1.sol";

import {TestToken} from "superfluid-finance/contracts/utils/TestToken.sol";

import {
    SuperfluidFrameworkDeployer,
    TestGovernance,
    Superfluid,
    ConstantFlowAgreementV1,
    InstantDistributionAgreementV1,
    IDAv1Library,
    CFAv1Library,
    SuperTokenFactory
} from "superfluid-finance/contracts/utils/SuperfluidFrameworkDeployer.sol";

import { SuperTokenV1Library } from "superfluid-finance/contracts/apps/SuperTokenV1Library.sol";

import { ContinuousRentalAuction } from "../src/ContinuousRentalAuction.sol";
import { IRentalAuctionControllerObserver } from "../src/interfaces/IRentalAuctionControllerObserver.sol";
import { IRentalAuction } from "../src/interfaces/IRentalAuction.sol";

// TODO: explicitly set gitmodules versions

contract ContinuousRentalAuctionWithTestFunctions is ContinuousRentalAuction {
    function updateSenderInfoListNode(int96 newRate, address sender, address right) public {
        _updateSenderInfoListNode(newRate, sender, right);
    }

    function removeSenderInfoListNode(address sender) public {
        _removeSenderInfoListNode(sender);
    }

    function insertSenderInfoListNode(int96 newRate, address newSender, address right) public {
        _insertSenderInfoListNode(newRate, newSender, right);
    }

}

contract ContinuousRentalAuctionTest is Test, IRentalAuctionControllerObserver {
    // SuperToken library setup
    using SuperTokenV1Library for ISuperToken;

    event RenterChanged(address indexed oldRenter, address indexed newRenter);
    event NewInboundStream(address indexed streamer, int96 flowRate);
    event StreamUpdated(address indexed streamer, int96 flowRate);
    event StreamTerminated(address indexed streamer);



    TestToken dai;
    ISuperToken daix;

    SuperfluidFrameworkDeployer.Framework sf;

    ContinuousRentalAuctionWithTestFunctions app;

    address bank = vm.addr(101);

    address beneficiary = vm.addr(102);

    uint256 totalSupply = 1_000_000 ether;

    uint96 constant minimumBidFactorWad = 1e18 / 20 + 1e18; // 1.05

    int96 reserveRate = 5;

    address reportedRenter;

    address constant reportedRenterPlaceholder = address(type(uint160).max);

    function setUp() public {
        SuperfluidFrameworkDeployer sfDeployer = new SuperfluidFrameworkDeployer();
        sf = sfDeployer.getFramework();
    
        (dai, daix) = sfDeployer.deployWrapperSuperToken(
            "Fake DAI", "DAI", 18, totalSupply
        );

        vm.startPrank(bank);
        dai.mint(bank, totalSupply);
        dai.approve(address(daix), totalSupply);
        daix.upgrade(totalSupply);
        vm.stopPrank();

        require(dai.balanceOf(bank) == 0);
        require(daix.balanceOf(bank) == totalSupply);


        app = new ContinuousRentalAuctionWithTestFunctions();

        uint256 configWord = SuperAppDefinitions.APP_LEVEL_FINAL | // TODO: for now assume final, later figure out how to remove this requirement safely
            SuperAppDefinitions.BEFORE_AGREEMENT_CREATED_NOOP |
            SuperAppDefinitions.BEFORE_AGREEMENT_UPDATED_NOOP |
            SuperAppDefinitions.BEFORE_AGREEMENT_TERMINATED_NOOP;

        ISuperfluid(sf.host).registerAppByFactory(app, configWord);
        app.initialize(daix, sf.host, sf.cfa, IRentalAuctionControllerObserver(address(this)), beneficiary, minimumBidFactorWad, reserveRate);
    }

    function onRenterChanged(address newRenter) public {
        reportedRenter = newRenter;
    }

    function initialize(IRentalAuction, bytes calldata) external {}

    function testNoDuplicateStreams() public {
        address sender = vm.addr(1);

        vm.prank(bank);
        daix.transfer(sender, 100 ether);

        vm.startPrank(sender);

        daix.createFlow(beneficiary, 1);

        vm.expectRevert(bytes4(keccak256("CFA_FLOW_ALREADY_EXISTS()")));
        daix.createFlow(beneficiary, 2);

        vm.stopPrank();
    }

    function testFailCreateStreamMustBeAtLeastReserveRate() public {
        address sender = vm.addr(1);

        vm.prank(bank);
        daix.transfer(sender, 100 ether);

        vm.prank(sender);
        // vm.expectRevert(bytes4(keccak256("FlowRateTooLow()")));
        daix.createFlow(address(app), reserveRate - 1, abi.encode(address(0), bytes("")));
    }

    function testUpdateStreamMustBeAtLeastReserveRate() public {
        address sender = vm.addr(1);

        testCreateFirstStream(reserveRate);

        vm.prank(sender);
        vm.expectRevert(bytes4(keccak256("FlowRateTooLow()")));
        daix.updateFlow(address(app), reserveRate - 1, abi.encode(address(0), bytes("hi")));
    }

    function testCreateFirstStream(int96 flowRate) public {
        vm.assume(flowRate < 0.01 ether && flowRate >= reserveRate);
        vm.assume(daix.getBufferAmountByFlowRate(flowRate) < 50 ether);

        reportedRenter = reportedRenterPlaceholder;

        address sender = vm.addr(1);
        bytes memory userData = bytes("user-data-1");

        vm.prank(bank);
        daix.transfer(sender, 100 ether);

        vm.startPrank(sender);
        
        vm.expectEmit(true, true, false, false);
        emit RenterChanged(address(0), sender);

        vm.expectEmit(true, false, false, true);
        emit NewInboundStream(sender, flowRate);
        
        daix.createFlow(address(app), flowRate, abi.encode(address(0), userData));
        
        vm.stopPrank();

        //// make sure onRenterChanged callback was called appropriately

        assertEq(reportedRenter, sender);

        //// check state

        (,int96 netFlowApp,,) = daix.getNetFlowInfo(address(app));
        (,int96 netFlowBeneficiary,,) = daix.getNetFlowInfo(beneficiary);
        (,int96 netFlowSender,,) = daix.getNetFlowInfo(sender);

        // currentRenter
        assertEq(app.currentRenter(), sender);

        // netFlow = 0
        assertEq(netFlowApp, 0);

        // beneficiary flow
        assertEq(netFlowBeneficiary, flowRate);
        
        // top streamer flow
        assertEq(netFlowSender, -flowRate);

        // user data
        assertEq(app.senderUserData(sender), userData);

        // assume list is proper
    }

    function testCreateSecondStreamLarger(int96 firstRate, int96 secondRate) public {
        vm.assume(firstRate != secondRate);
        vm.assume(firstRate < 0.01 ether && firstRate >= reserveRate);
        vm.assume(daix.getBufferAmountByFlowRate(firstRate) < 50 ether);
        vm.assume(secondRate < 0.01 ether && secondRate >= reserveRate);
        vm.assume(daix.getBufferAmountByFlowRate(secondRate) < 50 ether);

        reportedRenter = reportedRenterPlaceholder;

        if (firstRate > secondRate) {
            int96 tmp = firstRate;
            firstRate = secondRate;
            secondRate = tmp;
        }

        vm.assume(app.isBidHigher(secondRate, firstRate));

        testCreateFirstStream(firstRate);

        address sender1 = vm.addr(1);
        address sender2 = vm.addr(2);

        bytes memory userData1 = bytes("user-data-1");
        bytes memory userData2 = bytes("user-data-2");

        vm.prank(bank);
        daix.transfer(sender2, 100 ether);

        vm.expectEmit(true, true, false, true);
        emit RenterChanged(sender1, sender2);

        vm.expectEmit(true, false, false, true);
        emit NewInboundStream(sender2, secondRate);
        
        vm.prank(sender2);
        daix.createFlow(address(app), secondRate, abi.encode(address(0), userData2));

        //// make sure onRenterChanged callback was called appropriately

        assertEq(reportedRenter, sender2);

        //// check state

        (,int96 netFlowApp,,) = daix.getNetFlowInfo(address(app));
        (,int96 netFlowBeneficiary,,) = daix.getNetFlowInfo(beneficiary);
        (,int96 netFlowSender1,,) = daix.getNetFlowInfo(sender1);
        (,int96 netFlowSender2,,) = daix.getNetFlowInfo(sender2);

        // currentRenter
        assertEq(app.currentRenter(), sender2);

        // netFlow = 0
        assertEq(netFlowApp, 0);

        // beneficiary flow
        assertEq(netFlowBeneficiary, secondRate);
        
        // top streamer flow
        assertEq(netFlowSender2, -secondRate);

        // losing streamer flow
        assertEq(netFlowSender1, 0);

        // user data
        assertEq(app.senderUserData(sender1), userData1);
        assertEq(app.senderUserData(sender2), userData2);

        // assume list is proper
    }

    function testCreateSecondStreamSmaller(int96 firstRate, int96 secondRate) public {
        vm.assume(firstRate != secondRate);
        vm.assume(firstRate < 0.01 ether && firstRate >= reserveRate);
        vm.assume(daix.getBufferAmountByFlowRate(firstRate) < 50 ether);
        vm.assume(secondRate < 0.01 ether && secondRate >= reserveRate);
        vm.assume(daix.getBufferAmountByFlowRate(secondRate) < 50 ether);

        if (secondRate > firstRate) {
            int96 tmp = firstRate;
            firstRate = secondRate;
            secondRate = tmp;
        }

        testCreateFirstStream(firstRate);

        reportedRenter = reportedRenterPlaceholder;

        address sender1 = vm.addr(1);
        address sender2 = vm.addr(2);

        bytes memory userData1 = bytes("user-data-1");
        bytes memory userData2 = bytes("user-data-2");

        vm.prank(bank);
        daix.transfer(sender2, 100 ether);

        vm.expectEmit(true, false, false, true);
        emit NewInboundStream(sender2, secondRate);
        
        vm.prank(sender2);
        daix.createFlow(address(app), secondRate, abi.encode(sender1, userData2));

        //// make sure onRenterChanged callback was NOT called

        assertEq(reportedRenter, reportedRenterPlaceholder);

        //// check state

        (,int96 netFlowApp,,) = daix.getNetFlowInfo(address(app));
        (,int96 netFlowBeneficiary,,) = daix.getNetFlowInfo(beneficiary);
        (,int96 netFlowSender1,,) = daix.getNetFlowInfo(sender1);
        (,int96 netFlowSender2,,) = daix.getNetFlowInfo(sender2);

        // currentRenter
        assertEq(app.currentRenter(), sender1);

        // netFlow = 0
        assertEq(netFlowApp, 0);

        // beneficiary flow
        assertEq(netFlowBeneficiary, firstRate);
        
        // top streamer flow
        assertEq(netFlowSender1, -firstRate);

        // losing streamer flow
        assertEq(netFlowSender2, 0);

        // user data
        assertEq(app.senderUserData(sender1), userData1);
        assertEq(app.senderUserData(sender2), userData2);

        // assume list is proper
    }

    // test updating a stream that is not the top, nor becomes the top
    function testUpdateStreamLowLow() public {
        testCreateSecondStreamLarger(100, 200);

        reportedRenter = reportedRenterPlaceholder;

        address sender1 = vm.addr(1);
        address sender2 = vm.addr(2);

        bytes memory newData = "new-data";

        vm.prank(sender1);
        vm.expectEmit(true, false, false, true);
        emit StreamUpdated(sender1, 150);
        daix.updateFlow(address(app), 150, abi.encode(sender2, newData));

        //// make sure onRenterChanged callback was NOT called

        assertEq(reportedRenter, reportedRenterPlaceholder);

        //// check state

        (,int96 netFlowApp,,) = daix.getNetFlowInfo(address(app));
        (,int96 netFlowBeneficiary,,) = daix.getNetFlowInfo(beneficiary);
        (,int96 netFlowSender1,,) = daix.getNetFlowInfo(sender1);
        (,int96 netFlowSender2,,) = daix.getNetFlowInfo(sender2);

        // currentRenter
        assertEq(app.currentRenter(), sender2);

        // netFlow = 0
        assertEq(netFlowApp, 0);

        // beneficiary flow
        assertEq(netFlowBeneficiary, 200);
        
        // top streamer flow
        assertEq(netFlowSender2, -200);

        // losing streamer flow
        assertEq(netFlowSender1, 0);

        // user data
        assertEq(app.senderUserData(sender1), "new-data");
        assertEq(app.senderUserData(sender2), "user-data-2");

        // assume list is proper
    }

    // test updating a stream that is not the top, but becomes the top
    function testUpdateStreamLowHigh() public {
        testCreateSecondStreamLarger(100, 200);

        reportedRenter = reportedRenterPlaceholder;

        address sender1 = vm.addr(1);
        address sender2 = vm.addr(2);

        bytes memory newData = "new-data";

        vm.prank(sender1);
        vm.expectEmit(true, true, false, false);
        emit RenterChanged(sender2, sender1);
        vm.expectEmit(true, false, false, true);
        emit StreamUpdated(sender1, 250);
        daix.updateFlow(address(app), 250, abi.encode(address(0), newData));

        //// make sure onRenterChanged callback was called

        assertEq(reportedRenter, sender1);

        //// check state

        (,int96 netFlowApp,,) = daix.getNetFlowInfo(address(app));
        (,int96 netFlowBeneficiary,,) = daix.getNetFlowInfo(beneficiary);
        (,int96 netFlowSender1,,) = daix.getNetFlowInfo(sender1);
        (,int96 netFlowSender2,,) = daix.getNetFlowInfo(sender2);

        // currentRenter
        assertEq(app.currentRenter(), sender1);

        // netFlow = 0
        assertEq(netFlowApp, 0);

        // beneficiary flow
        assertEq(netFlowBeneficiary, 250);
        
        // top streamer flow
        assertEq(netFlowSender1, -250);

        // losing streamer flow
        assertEq(netFlowSender2, 0);

        // user data
        assertEq(app.senderUserData(sender1), "new-data");
        assertEq(app.senderUserData(sender2), "user-data-2");

        // assume list is proper
    }

    // test updating a stream that is top, but moves down the list
    function testUpdateStreamHighLow() public {
        testCreateSecondStreamLarger(100, 200);

        reportedRenter = reportedRenterPlaceholder;

        address sender1 = vm.addr(1);
        address sender2 = vm.addr(2);

        bytes memory newData = "new-data";

        vm.prank(sender2);
        vm.expectEmit(true, true, false, false);
        emit RenterChanged(sender2, sender1);
        vm.expectEmit(true, false, false, true);
        emit StreamUpdated(sender2, 50);
        daix.updateFlow(address(app), 50, abi.encode(address(sender1), newData));

        //// make sure onRenterChanged callback was called

        assertEq(reportedRenter, sender1);

        //// check state

        (,int96 netFlowApp,,) = daix.getNetFlowInfo(address(app));
        (,int96 netFlowBeneficiary,,) = daix.getNetFlowInfo(beneficiary);
        (,int96 netFlowSender1,,) = daix.getNetFlowInfo(sender1);
        (,int96 netFlowSender2,,) = daix.getNetFlowInfo(sender2);

        // currentRenter
        assertEq(app.currentRenter(), sender1);

        // netFlow = 0
        assertEq(netFlowApp, 0);

        // beneficiary flow
        assertEq(netFlowBeneficiary, 100);
        
        // top streamer flow
        assertEq(netFlowSender1, -100);

        // losing streamer flow
        assertEq(netFlowSender2, 0);

        // user data
        assertEq(app.senderUserData(sender1), "user-data-1");
        assertEq(app.senderUserData(sender2), "new-data");

        // assume list is proper
    }

    function testTerminateOnlyStream(int96 flowRate) public {
        testCreateFirstStream(flowRate);

        reportedRenter = reportedRenterPlaceholder;

        address sender = vm.addr(1);

        vm.prank(sender);
        vm.expectEmit(true, true, false, false);
        emit RenterChanged(sender, address(0));
        vm.expectEmit(true, false, false, false);
        emit StreamTerminated(sender);
        daix.deleteFlow(sender, address(app));

        //// make sure onRenterChanged callback was called

        assertEq(reportedRenter, address(0));

        //// check state

        (,int96 netFlowApp,,) = daix.getNetFlowInfo(address(app));
        (,int96 netFlowBeneficiary,,) = daix.getNetFlowInfo(beneficiary);
        (,int96 netFlowSender,,) = daix.getNetFlowInfo(sender);

        // currentRenter
        assertEq(app.currentRenter(), address(0));

        // netFlow = 0
        assertEq(netFlowApp, 0);

        // beneficiary flow
        assertEq(netFlowBeneficiary, 0);

        // deleted streamer flow
        assertEq(netFlowSender, 0);

        // assume list is proper
    }

    function testTerminateTopOfTwoStreams() public {
        testCreateSecondStreamLarger(100, 200);

        address sender1 = vm.addr(1);
        address sender2 = vm.addr(2);

        reportedRenter = reportedRenterPlaceholder;

        vm.prank(sender2);
        vm.expectEmit(true, true, false, false);
        emit RenterChanged(sender2, sender1);
        vm.expectEmit(true, false, false, false);
        emit StreamTerminated(sender2);
        daix.deleteFlow(sender2, address(app));

        //// make sure onRenterChanged callback was called appropriately

        assertEq(reportedRenter, sender1);

        //// check state

        (,int96 netFlowApp,,) = daix.getNetFlowInfo(address(app));
        (,int96 netFlowBeneficiary,,) = daix.getNetFlowInfo(beneficiary);
        (,int96 netFlowSender1,,) = daix.getNetFlowInfo(sender1);
        (,int96 netFlowSender2,,) = daix.getNetFlowInfo(sender2);

        // currentRenter
        assertEq(app.currentRenter(), sender1);

        // netFlow = 0
        assertEq(netFlowApp, 0);

        // beneficiary flow
        assertEq(netFlowBeneficiary, 100);

        // deleted streamer flow
        assertEq(netFlowSender2, 0);

        // new top streamer flow
        assertEq(netFlowSender1, -100);

        // assume list is proper
    }

    function testTerminateBottomOfTwoStreams() public {
        testCreateSecondStreamLarger(100, 200);

        reportedRenter = reportedRenterPlaceholder;

        address sender1 = vm.addr(1);
        address sender2 = vm.addr(2);

        vm.prank(sender1);
        vm.expectEmit(true, false, false, false);
        emit StreamTerminated(sender1);
        daix.deleteFlow(sender1, address(app));

        //// make sure onRenterChanged callback was NOT called

        assertEq(reportedRenter, reportedRenterPlaceholder);

        //// check state

        (,int96 netFlowApp,,) = daix.getNetFlowInfo(address(app));
        (,int96 netFlowBeneficiary,,) = daix.getNetFlowInfo(beneficiary);
        (,int96 netFlowSender1,,) = daix.getNetFlowInfo(sender1);
        (,int96 netFlowSender2,,) = daix.getNetFlowInfo(sender2);

        // currentRenter
        assertEq(app.currentRenter(), sender2);

        // netFlow = 0
        assertEq(netFlowApp, 0);

        // beneficiary flow
        assertEq(netFlowBeneficiary, 200);

        // deleted streamer flow
        assertEq(netFlowSender1, 0);

        // top streamer flow
        assertEq(netFlowSender2, -200);

        // assume list is proper
    }

    /*******************************************************
     * 
     * Controller Operations
     * 
     *******************************************************/

    function testPausingAccessControl() public {
        vm.prank(vm.addr(1));
        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        app.pause();

        vm.prank(vm.addr(1));
        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        app.unpause();
    }

    function testPause() public {
        testCreateSecondStreamLarger(100, 200);
        app.pause();

        //// check state

        address sender1 = vm.addr(1);
        address sender2 = vm.addr(2);

        (,int96 netFlowApp,,) = daix.getNetFlowInfo(address(app));
        (,int96 netFlowBeneficiary,,) = daix.getNetFlowInfo(beneficiary);
        (,int96 netFlowSender1,,) = daix.getNetFlowInfo(sender1);
        (,int96 netFlowSender2,,) = daix.getNetFlowInfo(sender2);

        // currentRenter
        assertEq(app.currentRenter(), sender2);

        // netFlow = 0
        assertEq(netFlowApp, 0);

        // beneficiary flow
        assertEq(netFlowBeneficiary, 0);

        assertEq(netFlowSender1, 0);
        assertEq(netFlowSender2, 0);
    }

    function testFailCreateStreamWhenPaused() public {
        // creating or updating a stream should revert when paused

        app.pause();

        address sender = vm.addr(1);
        bytes memory userData = bytes("user-data-1");

        vm.prank(bank);
        daix.transfer(sender, 100 ether);

        vm.prank(sender);
        // vm.expectRevert(bytes4(keccak256("Paused()"))); // for some reason this doesn't work
        daix.createFlow(address(app), 10, abi.encode(address(0), userData));
    }

    function testUpdateStreamWhenPaused() public {
        // creating or updating a stream should revert when paused

        testCreateFirstStream(100);

        app.pause();

        address sender = vm.addr(1);
        bytes memory userData = bytes("user-data-1");

        vm.prank(sender);
        vm.expectRevert(bytes4(keccak256("Paused()")));
        daix.updateFlow(address(app), 10, abi.encode(address(0), userData));
    }

    function testTerminateLowerStreamWhenPaused() public {
        testCreateSecondStreamLarger(100, 200);

        app.pause();

        address sender = vm.addr(1);

        vm.prank(sender);
        daix.deleteFlow(sender, address(app));

        //// check state

        address sender1 = vm.addr(1);
        address sender2 = vm.addr(2);

        (,int96 netFlowApp,,) = daix.getNetFlowInfo(address(app));
        (,int96 netFlowBeneficiary,,) = daix.getNetFlowInfo(beneficiary);
        (,int96 netFlowSender1,,) = daix.getNetFlowInfo(sender1);
        (,int96 netFlowSender2,,) = daix.getNetFlowInfo(sender2);

        // currentRenter
        assertEq(app.currentRenter(), sender2);

        // netFlow = 0
        assertEq(netFlowApp, 0);

        // beneficiary flow
        assertEq(netFlowBeneficiary, 0);

        assertEq(netFlowSender1, 0);
        assertEq(netFlowSender2, 0);
    }

    function testTerminateTopStreamWhenPaused() public {
        testCreateSecondStreamLarger(100, 200);

        app.pause();

        address sender1 = vm.addr(1);
        address sender2 = vm.addr(2);

        vm.prank(sender2);
        vm.expectEmit(true, true, false, false);
        emit RenterChanged(sender2, sender1);
        daix.deleteFlow(sender2, address(app));

        //// check state

        (,int96 netFlowApp,,) = daix.getNetFlowInfo(address(app));
        (,int96 netFlowBeneficiary,,) = daix.getNetFlowInfo(beneficiary);
        (,int96 netFlowSender1,,) = daix.getNetFlowInfo(sender1);
        (,int96 netFlowSender2,,) = daix.getNetFlowInfo(sender2);

        // currentRenter
        assertEq(app.currentRenter(), sender1);

        // netFlow = 0
        assertEq(netFlowApp, 0);

        // beneficiary flow
        assertEq(netFlowBeneficiary, 0);

        assertEq(netFlowSender1, 0);
        assertEq(netFlowSender2, 0);
    }

    function testTerminateOnlyStreamWhenPaused() public {
        testCreateFirstStream(100);
        app.pause();

        address sender = vm.addr(1);

        vm.prank(sender);
        vm.expectEmit(true, true, false, false);
        emit RenterChanged(sender, address(0));
        daix.deleteFlow(sender, address(app));

        //// check state

        (,int96 netFlowApp,,) = daix.getNetFlowInfo(address(app));
        (,int96 netFlowBeneficiary,,) = daix.getNetFlowInfo(beneficiary);
        (,int96 netFlowSender,,) = daix.getNetFlowInfo(sender);

        // currentRenter
        assertEq(app.currentRenter(), address(0));

        // netFlow = 0
        assertEq(netFlowApp, 0);

        // beneficiary flow
        assertEq(netFlowBeneficiary, 0);

        assertEq(netFlowSender, 0);
    }

    // TODO: test unpause when there are some streams
    // TODO: make sure onRenterChanged callback is NOT called in afterAgreementTerminated callback when auction is paused
    // TODO: test bidder in 2nd place has close to 0 daix when 1st place deletes their stream

    /*******************************************************
     * 
     * Linked List Operations
     * 
     *******************************************************/

    function assertLinkedListNode(address id, address left, address right, int96 flowRate) private view {
        (int96 _flowRate, address _left, address _right, address _id) = app.senderInfo(id);
        require(_id == id, "List node has incorrect sender");
        require(_left == left, "List node has incorrect left");
        require(_right == right, "List node has incorrect right");
        require(_flowRate == flowRate, "List node has incorrect flowRate");
    }

    function testFirstInsertion() public {
        // insert first one. cant revert
        app.insertSenderInfoListNode(50, address(50), address(0));

        assertLinkedListNode(address(50), address(0), address(0), 50);
        require(app.currentRenter() == address(50));
    }

    function testSecondInsertion() public {
        testFirstInsertion();

        // insert second one with position too high
        vm.expectRevert(bytes4(keccak256("FlowRateTooLow()")));
        app.insertSenderInfoListNode(40, address(40), address(0));

        // insert second one with position too low
        vm.expectRevert(bytes4(keccak256("FlowRateTooHigh()")));
        app.insertSenderInfoListNode(60, address(60), address(50));
        
        // insert second one successfully (to the right)
        app.insertSenderInfoListNode(60, address(60), address(0));
        assertLinkedListNode(address(60), address(50), address(0), 60);
        assertLinkedListNode(address(50), address(0), address(60), 50);
        require(app.currentRenter() == address(60));
    }

    function testThirdInsertion() public {
        testSecondInsertion(); // -> 50 - 60

        // insert third one with position too high
        vm.expectRevert(bytes4(keccak256("FlowRateTooLow()")));
        app.insertSenderInfoListNode(55, address(55), address(0));
        vm.expectRevert(bytes4(keccak256("FlowRateTooLow()")));
        app.insertSenderInfoListNode(45, address(45), address(60));

        // insert third one with position too low
        vm.expectRevert(bytes4(keccak256("FlowRateTooHigh()")));
        app.insertSenderInfoListNode(65, address(65), address(60));
        vm.expectRevert(bytes4(keccak256("FlowRateTooHigh()")));
        app.insertSenderInfoListNode(55, address(55), address(50));
        
        // insert third one successfully (in the middle) = 50 - 55 - 60
        app.insertSenderInfoListNode(55, address(55), address(60));
        assertLinkedListNode(address(50), address(0), address(55), 50);
        assertLinkedListNode(address(55), address(50), address(60), 55);
        assertLinkedListNode(address(60), address(55), address(0), 60);
        require(app.currentRenter() == address(60));
    }

    function testInsertionFlowRateMustBeFarEnoughFromNeighbors() public {
        testThirdInsertion(); // 50 - 55 - 60

        // cannot be equal to the right
        vm.expectRevert(bytes4(keccak256("FlowRateTooHigh()")));
        app.insertSenderInfoListNode(60, address(91240), address(60));
        
        // cannot be equal to the left
        vm.expectRevert(bytes4(keccak256("FlowRateTooLow()")));
        app.insertSenderInfoListNode(55, address(124999137), address(60));

        // cannot be too close to the left
        vm.expectRevert(bytes4(keccak256("FlowRateTooLow()")));
        app.insertSenderInfoListNode(56, address(124999137), address(60));

        // can be close to the right
        app.insertSenderInfoListNode(59, address(124999137), address(60));
    }

    function testUpdateFlowRateMustBeFarEnoughFromNeighbors() public {
        testThirdInsertion(); // 50 - 55 - 60

        // cannot be equal to the right
        vm.expectRevert(bytes4(keccak256("FlowRateTooHigh()")));
        app.updateSenderInfoListNode(60, address(55), address(60));
        
        // cannot be equal to the left
        vm.expectRevert(bytes4(keccak256("FlowRateTooLow()")));
        app.updateSenderInfoListNode(50, address(55), address(60));

        // cannot be too close to the left
        vm.expectRevert(bytes4(keccak256("FlowRateTooLow()")));
        app.updateSenderInfoListNode(51, address(55), address(60));

        // can be close to the right
        app.updateSenderInfoListNode(59, address(55), address(60));
    }

    function testInsertionAndUpdateWithNonexistentRight() public {
        testThirdInsertion();

        vm.expectRevert(bytes4(keccak256("InvalidRight()")));
        app.insertSenderInfoListNode(1000, vm.addr(1), vm.addr(2));

        vm.expectRevert(bytes4(keccak256("InvalidRight()")));
        app.insertSenderInfoListNode(1000, address(60), vm.addr(2));
    }
    
    function testSuccessfulLowerRemoval() public {
        testThirdInsertion(); // 50 - 55 - 60

        // remove leftmost
        app.removeSenderInfoListNode(address(50));
        assertLinkedListNode(address(55), address(0), address(60), 55);
        assertLinkedListNode(address(60), address(55), address(0), 60);
        require(app.currentRenter() == address(60));
    }

    function testSuccessfulMiddleRemoval() public {
        testThirdInsertion(); // 50 - 55 - 60

        // remove middle
        app.removeSenderInfoListNode(address(55));
        assertLinkedListNode(address(50), address(0), address(60), 50);
        assertLinkedListNode(address(60), address(50), address(0), 60);
        require(app.currentRenter() == address(60));
    }

    function testSuccessfulUpperRemoval() public {
        testThirdInsertion(); // 50 - 55 - 60

        // remove middle
        app.removeSenderInfoListNode(address(60));
        assertLinkedListNode(address(50), address(0), address(55), 50);
        assertLinkedListNode(address(55), address(50), address(0), 55);
        require(app.currentRenter() == address(55));
    }

    // test update

    function testSuccessfulLowerInPlaceUpdate() public {
        testThirdInsertion();

        app.updateSenderInfoListNode(45, address(50), address(55));
        assertLinkedListNode(address(50), address(0), address(55), 45);
        assertLinkedListNode(address(55), address(50), address(60), 55);
        assertLinkedListNode(address(60), address(55), address(0), 60);
        require(app.currentRenter() == address(60));
    }

    function testSuccessfulMiddleInPlaceUpdate() public {
        testThirdInsertion();

        app.updateSenderInfoListNode(54, address(55), address(60));
        assertLinkedListNode(address(50), address(0), address(55), 50);
        assertLinkedListNode(address(55), address(50), address(60), 54);
        assertLinkedListNode(address(60), address(55), address(0), 60);
        require(app.currentRenter() == address(60));
    }

    function testSuccessfulUpperInPlaceUpdate() public {
        testThirdInsertion();

        app.updateSenderInfoListNode(65, address(60), address(0));
        assertLinkedListNode(address(50), address(0), address(55), 50);
        assertLinkedListNode(address(55), address(50), address(60), 55);
        assertLinkedListNode(address(60), address(55), address(0), 65);
        require(app.currentRenter() == address(60));
    }

    function testSuccessfulLowerToUpperUpdate() public {
        testThirdInsertion();

        app.updateSenderInfoListNode(65, address(50), address(0));
        assertLinkedListNode(address(50), address(60), address(0), 65);
        assertLinkedListNode(address(55), address(0), address(60), 55);
        assertLinkedListNode(address(60), address(55), address(50), 60);
        require(app.currentRenter() == address(50));
    }

    function testSuccessfulUpperToLowerUpdate() public {
        testThirdInsertion(); // 50 - 55 - 60

        app.updateSenderInfoListNode(1, address(60), address(50)); // 60 - 50 - 55
        assertLinkedListNode(address(50), address(60), address(55), 50);
        assertLinkedListNode(address(55), address(50), address(0), 55);
        assertLinkedListNode(address(60), address(0), address(50), 1);
        require(app.currentRenter() == address(55));
    }

    function testBadInPlaceUpdate() public {
        testThirdInsertion();

        // should fail b/c rate is equal to left
        vm.expectRevert(bytes4(keccak256("FlowRateTooLow()")));
        app.updateSenderInfoListNode(5, address(55), address(60));

        // should fail b/c rate is equal to left
        vm.expectRevert(bytes4(keccak256("FlowRateTooHigh()")));
        app.updateSenderInfoListNode(60, address(55), address(60));
    }
}
