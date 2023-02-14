// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

// import {ISuperfluid, SuperAppDefinitions, BatchOperation} from "superfluid-finance/contracts/interfaces/superfluid/ISuperfluid.sol";

import {ISuperToken} from "superfluid-finance/contracts/interfaces/superfluid/ISuperToken.sol";
// import {ISuperTokenFactory} from "superfluid-finance/contracts/interfaces/superfluid/ISuperTokenFactory.sol";
// import {IConstantFlowAgreementV1} from "superfluid-finance/contracts/interfaces/agreements/IConstantFlowAgreementV1.sol";

// import {TestToken} from "superfluid-finance/contracts/utils/TestToken.sol";

// import {
//     SuperfluidFrameworkDeployer,
//     TestGovernance,
//     Superfluid,
//     ConstantFlowAgreementV1,
//     InstantDistributionAgreementV1,
//     IDAv1Library,
//     CFAv1Library,
//     SuperTokenFactory
// } from "superfluid-finance/contracts/utils/SuperfluidFrameworkDeployer.sol";


import { SuperTokenV1Library } from "superfluid-finance/contracts/apps/SuperTokenV1Library.sol";

// import { IRentalAuctionControllerObserver } from "../src/interfaces/IRentalAuctionControllerObserver.sol";
import { IRentalAuction } from "../src/interfaces/IRentalAuction.sol";

import { LensProfileControllerObserver } from "../src/controllers/LensProfileControllerObserver.sol";
import { ILensHub } from "../src/interfaces/ILensHub.sol";
import { LensDataTypes } from "../src/libraries/LensDataTypes.sol";


contract LensProfileControllerObserverTest is Test, IRentalAuction {
    // SuperToken library setup
    using SuperTokenV1Library for ISuperToken;

    address profileHolder = vm.addr(1111);

    ILensHub lensHub = ILensHub(0x60Ae865ee4C725cd04353b5AAb364553f56ceF82);

    address collectModule = 0x5E70fFD2C6D04d65C3abeBa64E93082cfA348dF8;

    address constant profileCreationProxy = 0x420f0257D43145bb002E69B14FF2Eb9630Fc4736;

    LensProfileControllerObserver controller;

    address public currentRenter;
    uint256 profileId;

    bool public paused;

    event PostCreated(
        uint256 indexed profileId,
        uint256 indexed pubId,
        string contentURI,
        address collectModule,
        bytes collectModuleReturnData,
        address referenceModule,
        bytes referenceModuleReturnData,
        uint256 timestamp
    );

    event AuctionStarted();
    event AuctionStopped();

    function setUp() external {
        controller = new LensProfileControllerObserver();

        string memory handle = "oiqfwefiow";

        profileId = mintProfile(profileHolder, handle);

        vm.prank(profileHolder);
        controller.initialize(
            IRentalAuction(this),
            profileHolder,
            abi.encode(profileId)
        );
    }

    function mintProfile(address to, string memory handle) private returns (uint256) {
        vm.prank(address(profileCreationProxy));
        return lensHub.createProfile(LensDataTypes.CreateProfileData(
            to,
            handle,
            "https://cdn.stamp.fyi/avatar/eth:0x0000000000000000000000000000000000000000?s=250",
            address(0),
            "",
            "ipfs://QmX2KjVsQUACTR7L1jqVogLxaApiYgtLBZzDnhDkddAZZp"
        ));
    }

    function makePostData() private view returns (LensDataTypes.PostData memory) {
        return LensDataTypes.PostData(
            profileId,
            "contentURI",
            collectModule,
            "",
            address(0),
            ""
        );
    }

    function makePost(address from, uint256 expectedPubId) private {
        // struct PostData {
        //     uint256 profileId;
        //     string contentURI;
        //     address collectModule;
        //     bytes collectModuleInitData;
        //     address referenceModule;
        //     bytes referenceModuleInitData;
        // }
        vm.prank(from);
        vm.expectEmit(true, true, true, true);
        emit PostCreated(profileId, expectedPubId, "contentURI", collectModule, "", address(0), "", block.timestamp);
        lensHub.post(makePostData());
    }

    function testOnlyOwner() external {
        vm.startPrank(vm.addr(1));
        
        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        controller.stopAuction();

        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        controller.startAuction();

        vm.stopPrank();
    }

    function testCanPostAsOwnerBeforeAuction() external {
        makePost(profileHolder, 1);
    }

    function testOnlyRenter() external {
        // vm.prank(vm.addr(1));
        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        controller.post(makePostData());
    }

    function testStartAuction() public {
        vm.startPrank(profileHolder);

        vm.expectRevert("ERC721: transfer caller is not owner nor approved");
        controller.startAuction();

        lensHub.approve(address(controller), profileId);

        vm.expectEmit(false, false, false, false);
        emit AuctionStarted();
        controller.startAuction();

        // make sure the controller has the profile now
        assertEq(lensHub.ownerOf(profileId), address(controller));

        vm.stopPrank();
    }

    function testStopAuction() external {
        testStartAuction();

        vm.prank(profileHolder);
        vm.expectEmit(false, false, false, false);
        emit AuctionStopped();
        controller.stopAuction();

        // make sure profileHolder has the profile now
        assertEq(lensHub.ownerOf(profileId), profileHolder);
    }

    function testPostAsRenter() external {
        vm.startPrank(profileHolder);
        lensHub.approve(address(controller), profileId);
        controller.startAuction();
        vm.stopPrank();

        currentRenter = vm.addr(1);

        vm.prank(currentRenter);
        controller.post(makePostData());
    }

    function pause() external override {}

    function unpause() external override {}

    function senderUserData(
        address sender
    ) external view override returns (bytes memory) {}
}
