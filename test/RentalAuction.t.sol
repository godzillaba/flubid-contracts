// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {ISuperfluid} from "superfluid-finance/contracts/interfaces/superfluid/ISuperfluid.sol";

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

import { RentalAuction } from "../src/RentalAuction.sol";

contract RentalAuctionWithTestFunctions is RentalAuction {
    constructor(
        ISuperToken _acceptedToken,
        ISuperfluid _host,
        IConstantFlowAgreementV1 _cfa,
        address _receiver
    )
    RentalAuction(_acceptedToken, _host, _cfa, _receiver) {}

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

contract RentalAuctionTest is Test {
    // SuperToken library setup
    using SuperTokenV1Library for ISuperToken;

    event NewTopStreamer(address indexed oldTopStreamer, address indexed newTopStreamer, int96 flowRate); // TODO: think more about indexed
    event NewInboundStream(address indexed streamer, int96 flowRate);

    TestToken dai;
    ISuperToken daix;

    SuperfluidFrameworkDeployer.Framework sf;

    RentalAuctionWithTestFunctions app;

    address bank = vm.addr(101);

    address beneficiary = vm.addr(102);

    uint256 totalSupply = 1_000_000 ether;

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


        app = new RentalAuctionWithTestFunctions(daix, sf.host, sf.cfa, beneficiary);
    }

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

    function testFirstStream(int96 flowRate) public {
        vm.assume(flowRate < 0.01 ether && flowRate > 0);
        vm.assume(daix.getBufferAmountByFlowRate(flowRate) < 50 ether);

        address sender = vm.addr(1);
        bytes memory userData = bytes("user-data-1");

        vm.prank(bank);
        daix.transfer(sender, 100 ether);

        vm.startPrank(sender);
        
        vm.expectEmit(true, true, false, true);
        emit NewTopStreamer(address(0), sender, flowRate);

        vm.expectEmit(true, false, false, true);
        emit NewInboundStream(sender, flowRate);
        
        daix.createFlow(address(app), flowRate, abi.encode(address(0), userData));
        
        vm.stopPrank();

        //// check state

        (,int96 netFlowApp,,) = daix.getNetFlowInfo(address(app));
        (,int96 netFlowBeneficiary,,) = daix.getNetFlowInfo(beneficiary);
        (,int96 netFlowSender,,) = daix.getNetFlowInfo(sender);

        // topStreamer
        assertEq(app.topStreamer(), sender);

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

    function testSecondStreamLarger(int96 firstRate, int96 secondRate) public {
        vm.assume(firstRate != secondRate);
        vm.assume(firstRate < 0.01 ether && firstRate > 0);
        vm.assume(daix.getBufferAmountByFlowRate(firstRate) < 50 ether);
        vm.assume(secondRate < 0.01 ether && secondRate > 0);
        vm.assume(daix.getBufferAmountByFlowRate(secondRate) < 50 ether);

        if (firstRate > secondRate) {
            int96 tmp = firstRate;
            firstRate = secondRate;
            secondRate = tmp;
        }

        testFirstStream(firstRate);

        address sender1 = vm.addr(1);
        address sender2 = vm.addr(2);

        bytes memory userData1 = bytes("user-data-1");
        bytes memory userData2 = bytes("user-data-2");

        vm.prank(bank);
        daix.transfer(sender2, 100 ether);

        vm.expectEmit(true, true, false, true);
        emit NewTopStreamer(sender1, sender2, secondRate);

        vm.expectEmit(true, false, false, true);
        emit NewInboundStream(sender2, secondRate);
        
        vm.prank(sender2);
        daix.createFlow(address(app), secondRate, abi.encode(address(0), userData2));

        //// check state

        (,int96 netFlowApp,,) = daix.getNetFlowInfo(address(app));
        (,int96 netFlowBeneficiary,,) = daix.getNetFlowInfo(beneficiary);
        (,int96 netFlowSender1,,) = daix.getNetFlowInfo(sender1);
        (,int96 netFlowSender2,,) = daix.getNetFlowInfo(sender2);

        // topStreamer
        assertEq(app.topStreamer(), sender2);

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

    function testSecondStreamSmaller(int96 firstRate, int96 secondRate) public {
        vm.assume(firstRate != secondRate);
        vm.assume(firstRate < 0.01 ether && firstRate > 0);
        vm.assume(daix.getBufferAmountByFlowRate(firstRate) < 50 ether);
        vm.assume(secondRate < 0.01 ether && secondRate > 0);
        vm.assume(daix.getBufferAmountByFlowRate(secondRate) < 50 ether);

        if (secondRate > firstRate) {
            int96 tmp = firstRate;
            firstRate = secondRate;
            secondRate = tmp;
        }

        testFirstStream(firstRate);

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

        //// check state

        (,int96 netFlowApp,,) = daix.getNetFlowInfo(address(app));
        (,int96 netFlowBeneficiary,,) = daix.getNetFlowInfo(beneficiary);
        (,int96 netFlowSender1,,) = daix.getNetFlowInfo(sender1);
        (,int96 netFlowSender2,,) = daix.getNetFlowInfo(sender2);

        // topStreamer
        assertEq(app.topStreamer(), sender1);

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


    // todo: should NOT emit NewTopStreamer inappropriately
    // todo: test access control including superfluid callbacks

    /*******************************************************
     * 
     * Linked List Operations
     * 
     *******************************************************/

    function assertLinkedListNode(address id, address left, address right, int96 flowRate) private view {
        (address _left, address _right, address _id, int96 _flowRate) = app.senderInfo(id);
        require(_id == id, "List node has incorrect sender");
        require(_left == left, "List node has incorrect left");
        require(_right == right, "List node has incorrect right");
        require(_flowRate == flowRate, "List node has incorrect flowRate");
    }

    function testFirstInsertion() public {
        // insert first one. cant revert
        app.insertSenderInfoListNode(50, address(50), address(0));

        assertLinkedListNode(address(50), address(0), address(0), 50);
        require(app.topStreamer() == address(50));
    }

    function testSecondInsertion() public {
        testFirstInsertion();

        // insert second one with position too high
        vm.expectRevert(bytes4(keccak256("PosTooHigh()")));
        app.insertSenderInfoListNode(40, address(40), address(0));

        // insert second one with position too low
        vm.expectRevert(bytes4(keccak256("PosTooLow()")));
        app.insertSenderInfoListNode(60, address(60), address(50));
        
        // insert second one successfully (to the right)
        app.insertSenderInfoListNode(60, address(60), address(0));
        assertLinkedListNode(address(60), address(50), address(0), 60);
        assertLinkedListNode(address(50), address(0), address(60), 50);
        require(app.topStreamer() == address(60));
    }

    function testThirdInsertion() public {
        testSecondInsertion(); // -> 50 - 60

        // insert third one with position too high
        vm.expectRevert(bytes4(keccak256("PosTooHigh()")));
        app.insertSenderInfoListNode(55, address(55), address(0));
        vm.expectRevert(bytes4(keccak256("PosTooHigh()")));
        app.insertSenderInfoListNode(45, address(45), address(60));

        // insert third one with position too low
        vm.expectRevert(bytes4(keccak256("PosTooLow()")));
        app.insertSenderInfoListNode(65, address(65), address(60));
        vm.expectRevert(bytes4(keccak256("PosTooLow()")));
        app.insertSenderInfoListNode(55, address(55), address(50));
        
        // insert third one successfully (in the middle) = 50 - 55 - 60
        app.insertSenderInfoListNode(55, address(55), address(60));
        assertLinkedListNode(address(50), address(0), address(55), 50);
        assertLinkedListNode(address(55), address(50), address(60), 55);
        assertLinkedListNode(address(60), address(55), address(0), 60);
        require(app.topStreamer() == address(60));
    }

    function testInsertionFlowRateCannotBeEqual() public {
        testThirdInsertion(); // 50 - 55 - 60

        // test cannot be equal to the right
        vm.expectRevert(bytes4(keccak256("PosTooLow()")));
        app.insertSenderInfoListNode(60, address(91240), address(60));
        
        // test cannot be equal to the left
        vm.expectRevert(bytes4(keccak256("PosTooHigh()")));
        app.insertSenderInfoListNode(55, address(124999137), address(60));
    }
    
    function testSuccessfulLowerRemoval() public {
        testThirdInsertion(); // 50 - 55 - 60

        // remove leftmost
        app.removeSenderInfoListNode(address(50));
        assertLinkedListNode(address(55), address(0), address(60), 55);
        assertLinkedListNode(address(60), address(55), address(0), 60);
        require(app.topStreamer() == address(60));
    }

    function testSuccessfulMiddleRemoval() public {
        testThirdInsertion(); // 50 - 55 - 60

        // remove middle
        app.removeSenderInfoListNode(address(55));
        assertLinkedListNode(address(50), address(0), address(60), 50);
        assertLinkedListNode(address(60), address(50), address(0), 60);
        require(app.topStreamer() == address(60));
    }

    function testSuccessfulUpperRemoval() public {
        testThirdInsertion(); // 50 - 55 - 60

        // remove middle
        app.removeSenderInfoListNode(address(60));
        assertLinkedListNode(address(50), address(0), address(55), 50);
        assertLinkedListNode(address(55), address(50), address(0), 55);
        require(app.topStreamer() == address(55));
    }

    // test update

    function testSuccessfulLowerInPlaceUpdate() public {
        testThirdInsertion();

        app.updateSenderInfoListNode(45, address(50), address(55));
        assertLinkedListNode(address(50), address(0), address(55), 45);
        assertLinkedListNode(address(55), address(50), address(60), 55);
        assertLinkedListNode(address(60), address(55), address(0), 60);
        require(app.topStreamer() == address(60));
    }

    function testSuccessfulMiddleInPlaceUpdate() public {
        testThirdInsertion();

        app.updateSenderInfoListNode(54, address(55), address(60));
        assertLinkedListNode(address(50), address(0), address(55), 50);
        assertLinkedListNode(address(55), address(50), address(60), 54);
        assertLinkedListNode(address(60), address(55), address(0), 60);
        require(app.topStreamer() == address(60));
    }

    function testSuccessfulUpperInPlaceUpdate() public {
        testThirdInsertion();

        app.updateSenderInfoListNode(65, address(60), address(0));
        assertLinkedListNode(address(50), address(0), address(55), 50);
        assertLinkedListNode(address(55), address(50), address(60), 55);
        assertLinkedListNode(address(60), address(55), address(0), 65);
        require(app.topStreamer() == address(60));
    }

    function testSuccessfulLowerToUpperUpdate() public {
        testThirdInsertion();

        app.updateSenderInfoListNode(65, address(50), address(0));
        assertLinkedListNode(address(50), address(60), address(0), 65);
        assertLinkedListNode(address(55), address(0), address(60), 55);
        assertLinkedListNode(address(60), address(55), address(50), 60);
        require(app.topStreamer() == address(50));
    }

    function testSuccessfulUpperToLowerUpdate() public {
        testThirdInsertion(); // 50 - 55 - 60

        app.updateSenderInfoListNode(1, address(60), address(50)); // 60 - 50 - 55
        assertLinkedListNode(address(50), address(60), address(55), 50);
        assertLinkedListNode(address(55), address(50), address(0), 55);
        assertLinkedListNode(address(60), address(0), address(50), 1);
        require(app.topStreamer() == address(55));
    }

    function testBadInPlaceUpdate() public {
        testThirdInsertion();

        // should fail b/c rate is equal to left
        vm.expectRevert(bytes4(keccak256("PosTooHigh()")));
        app.updateSenderInfoListNode(5, address(55), address(60));

        // should fail b/c rate is equal to left
        vm.expectRevert(bytes4(keccak256("PosTooLow()")));
        app.updateSenderInfoListNode(60, address(55), address(60));
    }
}
