// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {ISuperfluid} from "superfluid-finance/contracts/interfaces/superfluid/ISuperfluid.sol";

import {ISuperToken} from "superfluid-finance/contracts/interfaces/superfluid/ISuperToken.sol";
import {ISuperTokenFactory} from "superfluid-finance/contracts/interfaces/superfluid/ISuperTokenFactory.sol";

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

contract RentalAuctionTest is Test {
    // SuperToken library setup
    using SuperTokenV1Library for ISuperToken;

    TestToken dai;
    ISuperToken daix;

    SuperfluidFrameworkDeployer.Framework sf;

    RentalAuction app;

    address bank = vm.addr(101);

    address beneficiary = vm.addr(102);

    function setUp() public {
        SuperfluidFrameworkDeployer sfDeployer = new SuperfluidFrameworkDeployer();
        sf = sfDeployer.getFramework();
    
        (dai, daix) = sfDeployer.deployWrapperSuperToken(
            "Fake DAI", "DAI", 18, 100 ether
        );

        vm.startPrank(bank);
        dai.mint(bank, 100 ether);
        dai.approve(address(daix), 100 ether);
        daix.upgrade(100 ether);
        vm.stopPrank();

        require(dai.balanceOf(bank) == 0);
        require(daix.balanceOf(bank) == 100 ether);


        app = new RentalAuction(daix, sf.host, sf.cfa, beneficiary);
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

    function assertLinkedListNode(address id, address left, address right) private view {
        (address _left, address _right, address _id, int96 _flowRate) = app.linkedListNodes(id);
        require(_id == id, "List node has incorrect sender");
        require(_left == left, "List node has incorrect left");
        require(_right == right, "List node has incorrect right");
        require(_flowRate == int96(uint96(uint160(id))), "List node has incorrect flowRate");
    }

    function testFirstInsertion() public {
        // insert first one. cant revert
        app.insertIntoList(50, address(50), address(0));

        assertLinkedListNode(address(50), address(0), address(0));
        require(app.topStreamer() == address(50));
    }

    function testSecondInsertion() public {
        testFirstInsertion();

        // insert second one with position too high
        vm.expectRevert(bytes4(keccak256("PosTooHigh()")));
        app.insertIntoList(40, address(40), address(0));

        // insert second one with position too low
        vm.expectRevert(bytes4(keccak256("PosTooLow()")));
        app.insertIntoList(60, address(60), address(50));
        
        // insert second one successfully (to the right)
        app.insertIntoList(60, address(60), address(0));
        assertLinkedListNode(address(60), address(50), address(0));
        assertLinkedListNode(address(50), address(0), address(60));
        require(app.topStreamer() == address(60));
    }

    function testThirdInsertion() public {
        testSecondInsertion(); // -> 50 - 60

        // insert third one with position too high
        vm.expectRevert(bytes4(keccak256("PosTooHigh()")));
        app.insertIntoList(55, address(55), address(0));
        vm.expectRevert(bytes4(keccak256("PosTooHigh()")));
        app.insertIntoList(45, address(45), address(60));

        // insert third one with position too low
        vm.expectRevert(bytes4(keccak256("PosTooLow()")));
        app.insertIntoList(65, address(65), address(60));
        vm.expectRevert(bytes4(keccak256("PosTooLow()")));
        app.insertIntoList(55, address(55), address(50));
        
        // insert third one successfully (in the middle) = 50 - 55 - 60
        app.insertIntoList(55, address(55), address(60));
        assertLinkedListNode(address(50), address(0), address(55));
        assertLinkedListNode(address(55), address(50), address(60));
        assertLinkedListNode(address(60), address(55), address(0));
        require(app.topStreamer() == address(60));
    }
}
