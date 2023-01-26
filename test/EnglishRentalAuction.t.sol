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

    uint256 minRentalDuration = 1 days;
    uint256 maxRentalDuration = 7 days;

    uint256 biddingPhaseDuration = 1 days;
    uint256 biddingPhaseExtensionDuration = 2 hours;

    address reportedWinner;

    address constant reportedWinnerPlaceholder = address(type(uint160).max);

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

    function onWinnerChanged(address newWinner) public {
        reportedWinner = newWinner;
    }

    function initialize(IRentalAuction, bytes calldata) external view {}

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

    function testSuccessfulBid(int96 flowRate) public {
        vm.assume(flowRate >= reserveRate);
        vm.assume(uint96(flowRate) * minRentalDuration < 0.5 ether);

        address user = vm.addr(1);

        vm.prank(bank);
        daix.transfer(user, 1 ether);

        ISuperfluid.Operation[] memory ops = new ISuperfluid.Operation[](3);

        ops[0] = createERC20ApprovalOperation();
        ops[1] = createFlowOperatorAuthorizationOperation();
        ops[2] = createSuperAppCallOperation(abi.encodeWithSignature("placeBid(int96,bytes)", flowRate, bytes("")));

        vm.prank(user);
        sf.host.batchCall(ops);

        // verify the app's state variables

        assertEq(app.currentWinner(), user);
        assertEq(app.topFlowRate(), flowRate);

        assertEq(app.isBiddingPhase(), true);
        assertEq(app.depositClaimed(), false);

        assertEq(app.currentPhaseEndTime(), block.timestamp + biddingPhaseDuration);

        // verify daix balances
        uint256 depositSize = minRentalDuration * uint96(flowRate);
        assertEq(daix.balanceOf(address(app)), depositSize);
        assertEq(daix.balanceOf(user), 1 ether - depositSize);

        // verify streams
        assertEq(daix.getNetFlowRate(address(app)), 0);
        assertEq(daix.getNetFlowRate(user), 0);
        assertEq(daix.getNetFlowRate(beneficiary), 0);
    }

    function testSuccessfullyTransitionToRentalPhase(int96 flowRate) public {
        vm.assume(flowRate > 0);
        
        testSuccessfulBid(flowRate);

        address renter = vm.addr(1);

        vm.warp(app.currentPhaseEndTime());

        app.transitionToRentalPhase();

        // verify app's state variables
        assertEq(app.currentWinner(), renter);
        assertEq(app.topFlowRate(), flowRate);

        assertEq(app.isBiddingPhase(), false);
        assertEq(app.depositClaimed(), false);

        assertEq(app.currentPhaseEndTime(), block.timestamp + maxRentalDuration);

        // verify daix balances
        uint256 depositSize = minRentalDuration * uint96(flowRate);
        assertEq(daix.balanceOf(address(app)), depositSize);

        // verify streams
        assertEq(daix.getNetFlowRate(address(app)), 0);
        assertEq(daix.getNetFlowRate(renter), -flowRate);
        assertEq(daix.getNetFlowRate(beneficiary), flowRate);
    }

    // function testFoo() public {
    //     testSuccessfullyTransitionToRentalPhase(5);

    //     vm.warp(block.timestamp + 1 hours);
    //     address renter = vm.addr(1);

    //     console.log(address(app), renter, address(sf.host), address(this));
    //     vm.prank(renter);
    //     sf.host.callAgreement(
    //         sf.cfa,
    //         abi.encodeCall(
    //             sf.cfa.deleteFlow,
    //             (daix, renter, address(app), new bytes(0))
    //         ),
    //         new bytes(0) // userData
    //     );
    //     // console.log(uint96(daix.getNetFlowRate(renter)));
    // }
    
    function testSuccessfullyTransitionToBiddingPhase(int96 flowRate) public {
        vm.assume(uint96(flowRate) * maxRentalDuration < 0.5 ether); // flow is small enough that they can pay for the entire duration

        testSuccessfullyTransitionToRentalPhase(flowRate);

        address renter = vm.addr(1);

        vm.warp(app.currentPhaseEndTime());

        (uint256 flowCreationTimestamp,,,) = daix.getFlowInfo(renter, address(app));

        app.transitionToBiddingPhase();

        // verify app's state variables
        assertEq(app.currentWinner(), renter); // this is undefined, doesn't have to be renter necessarily
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
    }
}