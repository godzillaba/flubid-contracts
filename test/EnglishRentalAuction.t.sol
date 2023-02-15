// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {ISuperfluid, SuperAppDefinitions, BatchOperation} from "superfluid-finance/contracts/interfaces/superfluid/ISuperfluid.sol";

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

import { EnglishRentalAuction } from "../src/EnglishRentalAuction.sol";
import { IRentalAuctionControllerObserver } from "../src/interfaces/IRentalAuctionControllerObserver.sol";
import { IRentalAuction } from "../src/interfaces/IRentalAuction.sol";

// TODO: make sure it does NOT transition to bidding phase when non-renter closes their stream during rental phase
// TODO: test events

contract EnglishRentalAuctionTest is Test, IRentalAuctionControllerObserver {
    // SuperToken library setup
    using SuperTokenV1Library for ISuperToken;

    event NewTopStreamer(address indexed oldTopStreamer, address indexed newTopStreamer);
    event NewInboundStream(address indexed streamer, int96 flowRate);
    event StreamUpdated(address indexed streamer, int96 flowRate);
    event StreamTerminated(address indexed streamer);



    TestToken dai;
    ISuperToken daix;

    SuperfluidFrameworkDeployer.Framework sf;

    EnglishRentalAuction app;

    address bank = vm.addr(101);

    address beneficiary = vm.addr(102);

    uint256 totalSupply = 1_000_000 ether;

    uint96 constant minimumBidFactorWad = 1e18 / 20 + 1e18; // 1.05

    int96 reserveRate = 5;

    uint64 minRentalDuration = 1 days;
    uint64 maxRentalDuration = 7 days;

    uint64 biddingPhaseDuration = 1 days;
    uint64 biddingPhaseExtensionDuration = 2 hours;

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


        app = new EnglishRentalAuction();

        // TODO: make sure app reverts on agreementUpdated

        // we want to support after creation, revert on updating, after termination
        uint256 configWord = SuperAppDefinitions.APP_LEVEL_FINAL | // TODO: for now assume final, later figure out how to remove this requirement safely
            SuperAppDefinitions.BEFORE_AGREEMENT_CREATED_NOOP |
            SuperAppDefinitions.AFTER_AGREEMENT_UPDATED_NOOP |
            SuperAppDefinitions.BEFORE_AGREEMENT_TERMINATED_NOOP;

        ISuperfluid(sf.host).registerAppByFactory(app, configWord);
        
        app.initialize(
            daix, 
            sf.host, 
            sf.cfa, 
            IRentalAuctionControllerObserver(address(this)), 
            beneficiary, 
            minimumBidFactorWad, 
            reserveRate,
            minRentalDuration,
            maxRentalDuration,
            biddingPhaseDuration,
            biddingPhaseExtensionDuration
        );
    }

    // todo: make sure this is only called ONCE. have a counter that is set to 0 before this is expected to be called
    function onRenterChanged(address newRenter) public {
        reportedRenter = newRenter;
    }

    function initialize(IRentalAuction, address, bytes calldata) external view {}

    function createERC20ApprovalOperation() private view returns (ISuperfluid.Operation memory op) {
        op.operationType = BatchOperation.OPERATION_TYPE_ERC20_APPROVE;
        op.target = address(daix);
        op.data = abi.encode(address(app), type(uint256).max);
    }

    function createFlowOperatorAuthorizationOperation() private view returns (ISuperfluid.Operation memory op) {
        op.operationType = BatchOperation.OPERATION_TYPE_SUPERFLUID_CALL_AGREEMENT;
        op.target = address(sf.cfa);
        bytes memory callData = abi.encodeWithSelector(IConstantFlowAgreementV1.authorizeFlowOperatorWithFullControl.selector, address(daix), address(app), bytes(""));
        op.data = abi.encode(callData, bytes(""));
    }

    function createSuperAppCallOperation(bytes memory data) private view returns (ISuperfluid.Operation memory op) {
        op.operationType = BatchOperation.OPERATION_TYPE_SUPERFLUID_CALL_APP_ACTION;
        op.target = address(app);
        op.data = data;
    }

    function testFirstBidTooLow() public {
        address user = vm.addr(1);
        int96 flowRate = reserveRate - 1;

        vm.prank(bank);
        daix.transfer(user, 1 ether);

        vm.prank(user);
        vm.expectRevert(bytes4(keccak256("FlowRateTooLow()")));
        app.placeBid(flowRate);

        vm.prank(user);
        vm.expectRevert(bytes4(keccak256("InvalidFlowRate()")));
        app.placeBid(0);

        vm.prank(user);
        vm.expectRevert(bytes4(keccak256("InvalidFlowRate()")));
        app.placeBid(-1);
    }

    function testBidWithoutApproval() public {
        address user = vm.addr(1);
        int96 flowRate = reserveRate;

        vm.prank(bank);
        daix.transfer(user, 1 ether);

        vm.prank(user);
        vm.expectRevert("SuperToken: transfer amount exceeds allowance");
        app.placeBid(flowRate);
    }

    function bid(address bidder, int96 flowRate) private {
        vm.prank(bank);
        daix.transfer(bidder, 1 ether);

        ISuperfluid.Operation[] memory ops = new ISuperfluid.Operation[](3);

        ops[0] = createERC20ApprovalOperation();
        ops[1] = createFlowOperatorAuthorizationOperation();
        ops[2] = createSuperAppCallOperation(abi.encodeWithSignature("placeBid(int96,bytes)", flowRate, bytes("")));

        vm.prank(bidder);
        sf.host.batchCall(ops);
    }

    function testSuccessfulBid(int96 flowRate) public {
        vm.assume(flowRate >= reserveRate);
        vm.assume(uint96(flowRate) * uint256(minRentalDuration) < 0.5 ether);

        address user = vm.addr(1);

        reportedRenter = reportedRenterPlaceholder;

        bid(user, flowRate);

        // verify the app's state variables

        assertEq(app.currentRenter(), address(0));
        assertEq(app.topFlowRate(), flowRate);

        assertEq(app.isBiddingPhase(), true);
        assertEq(app.depositClaimed(), false);

        assertEq(app.currentPhaseEndTime(), block.timestamp + biddingPhaseDuration);

        // verify daix balances
        uint256 depositSize = uint256(minRentalDuration) * uint96(flowRate);
        assertEq(daix.balanceOf(address(app)), depositSize);
        assertEq(daix.balanceOf(user), 1 ether - depositSize);

        // verify streams
        assertEq(daix.getNetFlowRate(address(app)), 0);
        assertEq(daix.getNetFlowRate(user), 0);
        assertEq(daix.getNetFlowRate(beneficiary), 0);

        // verify callback
        assertEq(reportedRenter, reportedRenterPlaceholder);
    }
    
    // // TODO
    // // function testSecondBidTooLow(int32 flowRate1, int32 flowRate2) public {

    // // }

    function testSecondBid(int32 flowRate1, int32 flowRate2) public {
        vm.assume(flowRate1 >= reserveRate);
        vm.assume(uint32(flowRate1) * uint256(minRentalDuration) < 0.5 ether);
        vm.assume(uint32(flowRate2) * uint256(minRentalDuration) < 0.5 ether);
        vm.assume(flowRate2 > 0 && app.isBidHigher(flowRate2, flowRate1));

        address bidder1 = vm.addr(1);
        address bidder2 = vm.addr(2);

        uint256 firstBidTs = block.timestamp;

        reportedRenter = reportedRenterPlaceholder;

        bid(bidder1, flowRate1);

        vm.warp(firstBidTs + biddingPhaseDuration - biddingPhaseExtensionDuration);

        bid(bidder2, flowRate2);

        // verify the app's state variables

        assertEq(app.currentRenter(), address(0));
        assertEq(app.topFlowRate(), flowRate2);

        assertEq(app.isBiddingPhase(), true);
        assertEq(app.depositClaimed(), false);

        assertEq(app.currentPhaseEndTime(), firstBidTs + biddingPhaseDuration);

        // verify daix balances
        uint256 depositSize = uint256(minRentalDuration) * uint32(flowRate2);
        assertEq(daix.balanceOf(address(app)), depositSize);
        assertEq(daix.balanceOf(bidder1), 1 ether);
        assertEq(daix.balanceOf(bidder2), 1 ether - depositSize);

        // verify streams
        assertEq(daix.getNetFlowRate(address(app)), 0);
        assertEq(daix.getNetFlowRate(bidder1), 0);
        assertEq(daix.getNetFlowRate(bidder2), 0);
        assertEq(daix.getNetFlowRate(beneficiary), 0);

        // verify callback
        assertEq(reportedRenter, reportedRenterPlaceholder);
    }

    function testSecondBidCloseToDeadline(int32 flowRate1, int32 flowRate2) public {
        // test second bid is close to the end of the bidding phase, so it gets extended

        vm.assume(flowRate1 >= reserveRate);
        vm.assume(uint32(flowRate1) * uint256(minRentalDuration) < 0.5 ether);
        vm.assume(uint32(flowRate2) * uint256(minRentalDuration) < 0.5 ether);
        vm.assume(flowRate2 > 0 && app.isBidHigher(flowRate2, flowRate1));

        address bidder1 = vm.addr(1);
        address bidder2 = vm.addr(2);

        uint256 firstBidTs = block.timestamp;

        reportedRenter = reportedRenterPlaceholder;

        bid(bidder1, flowRate1);

        vm.warp(firstBidTs + biddingPhaseDuration - biddingPhaseExtensionDuration + 1);
        uint256 secondBidTs = block.timestamp;
        bid(bidder2, flowRate2);

        // verify the app's state variables

        assertEq(app.currentRenter(), address(0));
        assertEq(app.topFlowRate(), flowRate2);

        assertEq(app.isBiddingPhase(), true);
        assertEq(app.depositClaimed(), false);

        assertEq(app.currentPhaseEndTime(), secondBidTs + biddingPhaseExtensionDuration);

        // verify daix balances
        uint256 depositSize = uint256(minRentalDuration) * uint32(flowRate2);
        assertEq(daix.balanceOf(address(app)), depositSize);
        assertEq(daix.balanceOf(bidder1), 1 ether);
        assertEq(daix.balanceOf(bidder2), 1 ether - depositSize);

        // verify streams
        assertEq(daix.getNetFlowRate(address(app)), 0);
        assertEq(daix.getNetFlowRate(bidder1), 0);
        assertEq(daix.getNetFlowRate(bidder2), 0);
        assertEq(daix.getNetFlowRate(beneficiary), 0);  

        // verify callback
        assertEq(reportedRenter, reportedRenterPlaceholder);
    }

    function testTransitionToRentalPhase(int96 flowRate) public {
        vm.assume(flowRate > 0);

        address renter = vm.addr(1);
        
        testSuccessfulBid(flowRate);

        reportedRenter = reportedRenterPlaceholder;

        vm.warp(app.currentPhaseEndTime());

        app.transitionToRentalPhase();

        // verify app's state variables
        assertEq(app.currentRenter(), renter);
        assertEq(app.topFlowRate(), flowRate);

        assertEq(app.isBiddingPhase(), false);
        assertEq(app.depositClaimed(), false);

        assertEq(app.currentPhaseEndTime(), block.timestamp + maxRentalDuration);

        // verify daix balances
        uint256 depositSize = uint256(minRentalDuration) * uint96(flowRate);
        assertEq(daix.balanceOf(address(app)), depositSize);

        // verify streams
        assertEq(daix.getNetFlowRate(address(app)), 0);
        assertEq(daix.getNetFlowRate(renter), -flowRate);
        assertEq(daix.getNetFlowRate(beneficiary), flowRate);

        // verify callback
        assertEq(reportedRenter, renter);
    }

    function testTransitionToBiddingPhase(int96 flowRate) public {
        vm.assume(uint96(flowRate) * uint256(maxRentalDuration) < 0.5 ether); // flow is small enough that they can pay for the entire duration

        testTransitionToRentalPhase(flowRate);

        address renter = vm.addr(1);

        vm.warp(app.currentPhaseEndTime());

        (uint256 flowCreationTimestamp,,,) = daix.getFlowInfo(renter, address(app));

        reportedRenter = reportedRenterPlaceholder;

        app.transitionToBiddingPhase();

        // verify app's state variables
        assertEq(app.currentRenter(), address(0));
        assertEq(app.topFlowRate(), 0);

        assertEq(app.isBiddingPhase(), true);
        assertEq(app.depositClaimed(), false);

        assertEq(app.currentPhaseEndTime(), 0);

        // verify daix balances
        uint256 amountFlowed = uint96(flowRate) * (block.timestamp - flowCreationTimestamp);
        assertEq(daix.balanceOf(address(app)), 0);
        assertEq(daix.balanceOf(beneficiary), amountFlowed);
        assertEq(daix.balanceOf(renter), 1 ether - amountFlowed);

        // verify streams
        assertEq(daix.getNetFlowRate(address(app)), 0);
        assertEq(daix.getNetFlowRate(renter), 0);
        assertEq(daix.getNetFlowRate(beneficiary), 0);

        // verify callback
        assertEq(reportedRenter, address(0));
    }

    function testRenterTerminateStreamAfterMinimumDuration(int32 _flowRate, uint32 duration) public {
        // renter terminates their stream before the maxRentalDuration has elapsed but after the uint256(minRentalDuration) has elapsed
        int96 flowRate = int96(_flowRate);

        vm.assume(duration >= uint256(minRentalDuration) && duration < maxRentalDuration * 3 / 2);
        vm.assume(uint96(flowRate) * uint256(maxRentalDuration) < 0.5 ether); // flow is small enough that they can pay for the entire duration

        testTransitionToRentalPhase(flowRate);

        reportedRenter = reportedRenterPlaceholder;

        vm.warp(block.timestamp + duration);

        address renter = vm.addr(1);

        // renter terminates their flow
        vm.prank(renter);
        sf.host.callAgreement(
            sf.cfa,
            abi.encodeCall(
                sf.cfa.deleteFlow,
                (daix, renter, address(app), new bytes(0))
            ),
            new bytes(0) // userData
        );

        // verify app's state variables
        assertEq(app.currentRenter(), address(0));
        assertEq(app.topFlowRate(), 0);

        assertEq(app.isBiddingPhase(), true);
        assertEq(app.depositClaimed(), false);

        assertEq(app.currentPhaseEndTime(), 0);

        // verify daix balances
        uint256 amountFlowed = uint96(flowRate) * duration;
        assertEq(daix.balanceOf(address(app)), 0);
        assertEq(daix.balanceOf(beneficiary), amountFlowed);
        assertEq(daix.balanceOf(renter), 1 ether - amountFlowed);

        // verify streams
        assertEq(daix.getNetFlowRate(address(app)), 0);
        assertEq(daix.getNetFlowRate(renter), 0);
        assertEq(daix.getNetFlowRate(beneficiary), 0);

        // verify callback
        assertEq(reportedRenter, address(0));
    }

    function testRenterTerminateStreamBeforeMinimumDuration(int32 _flowRate, uint32 duration) public {
        // renter terminates their stream before the uint256(minRentalDuration) has elapsed
        int96 flowRate = int96(int32(_flowRate));

        vm.assume(duration < uint256(minRentalDuration));
        vm.assume(uint96(flowRate) * uint256(maxRentalDuration) < 0.5 ether); // flow is small enough that they can pay for the entire duration

        testTransitionToRentalPhase(flowRate);

        reportedRenter = reportedRenterPlaceholder;

        vm.warp(block.timestamp + duration);

        address renter = vm.addr(1);

        // renter terminates their flow
        vm.prank(renter);
        sf.host.callAgreement(
            sf.cfa,
            abi.encodeCall(
                sf.cfa.deleteFlow,
                (daix, renter, address(app), new bytes(0))
            ),
            new bytes(0) // userData
        );

        // verify app's state variables
        assertEq(app.currentRenter(), address(0)); // this is undefined, doesn't have to be renter necessarily
        assertEq(app.topFlowRate(), 0);

        assertEq(app.isBiddingPhase(), true);
        assertEq(app.depositClaimed(), false);

        assertEq(app.currentPhaseEndTime(), 0);

        // verify daix balances
        uint256 depositSize = uint96(flowRate) * uint256(minRentalDuration);
        assertEq(daix.balanceOf(address(app)), 0);
        assertEq(daix.balanceOf(beneficiary), depositSize);
        assertEq(daix.balanceOf(renter), 1 ether - depositSize);

        // verify streams
        assertEq(daix.getNetFlowRate(address(app)), 0);
        assertEq(daix.getNetFlowRate(renter), 0);
        assertEq(daix.getNetFlowRate(beneficiary), 0);

        // verify callback
        assertEq(reportedRenter, address(0));
    }

    function testReclaimDeposit(int96 flowRate) public {
        address renter = vm.addr(1);

        vm.expectRevert(bytes4(keccak256("NotRentalPhase()")));
        app.reclaimDeposit();

        testTransitionToRentalPhase(flowRate);

        uint256 rentalStartTs = block.timestamp;
        
        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        app.reclaimDeposit();

        vm.prank(renter);
        vm.expectRevert(bytes4(keccak256("TooEarlyToReclaimDeposit()")));
        app.reclaimDeposit();

        vm.warp(rentalStartTs + uint256(minRentalDuration) - 1);

        vm.prank(renter);
        vm.expectRevert(bytes4(keccak256("TooEarlyToReclaimDeposit()")));
        app.reclaimDeposit();

        vm.warp(rentalStartTs + uint256(minRentalDuration));

        vm.prank(renter);
        app.reclaimDeposit();

        // verify app's state variables
        assertEq(app.currentRenter(), renter);
        assertEq(app.topFlowRate(), flowRate);

        assertEq(app.isBiddingPhase(), false);
        assertEq(app.depositClaimed(), true);

        assertEq(app.currentPhaseEndTime(), rentalStartTs + maxRentalDuration);

        // verify daix balances
        uint256 streamedAmount = (block.timestamp - rentalStartTs) * uint96(flowRate);
        assertEq(daix.balanceOf(address(app)), 0);
        assertEq(daix.balanceOf(beneficiary), streamedAmount);
        assertLt(daix.balanceOf(renter), 1 ether - streamedAmount); // less than because of superfluid deposit

        // verify streams
        assertEq(daix.getNetFlowRate(address(app)), 0);
        assertEq(daix.getNetFlowRate(renter), -flowRate);
        assertEq(daix.getNetFlowRate(beneficiary), flowRate);


        // should fail when they try to do it again
        vm.prank(renter);
        vm.expectRevert(bytes4(keccak256("DepositAlreadyClaimed()")));
        app.reclaimDeposit();
    }

    function testPauseFailing(int96 flowRate) public {
        vm.prank(vm.addr(1));
        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        app.pause();

        testTransitionToRentalPhase(flowRate);

        vm.expectRevert(bytes4(keccak256("NotBiddingPhase()")));
        app.pause();
    }

    function testPauseSuccess() public {
        int96 flowRate = reserveRate;

        address bidder = vm.addr(1);

        bid(bidder, flowRate);

        app.pause();

        // verify the app's state variables

        assertEq(app.currentRenter(), address(0));
        assertEq(app.topFlowRate(), 0);

        assertEq(app.isBiddingPhase(), true);
        assertEq(app.depositClaimed(), false);

        assertEq(app.currentPhaseEndTime(), 0);

        assertEq(app.paused(), true);

        // verify daix balances
        assertEq(daix.balanceOf(address(app)), 0);
        assertEq(daix.balanceOf(bidder), 1 ether);

        // verify streams
        assertEq(daix.getNetFlowRate(address(app)), 0);
        assertEq(daix.getNetFlowRate(bidder), 0);
        assertEq(daix.getNetFlowRate(beneficiary), 0);
    }
}
