// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import {ERC721} from "openzeppelin-contracts/token/ERC721/ERC721.sol";
import { IRentalAuction } from "../src/interfaces/IRentalAuction.sol";

import { ControllerObserver } from "../src/controllers/ControllerObserver.sol";

contract ERC721Mintable is ERC721 {
    constructor(string memory name_, string memory symbol_) ERC721(name_, symbol_) {}
    function mint(uint256 tokenId) external {
        _mint(msg.sender, tokenId);
    }
}

contract TestControllerObserver is ControllerObserver {
    uint256 onRenterChangedCallNum;
    address reportedRenter;
    function _onRenterChanged(address newRenter) internal virtual override {}

    function resetReportedRenter() external {
        reportedRenter = address(type(uint160).max);
        onRenterChangedCallNum = 0;
    }
}

contract LensProfileControllerObserverTest is Test, IRentalAuction {
    ERC721Mintable tokenContract;
    TestControllerObserver controllerObserver;

    bool public paused;

    uint256 tokenId = 1;

    address tokenHolder = vm.addr(101);

    event AuctionStopped();
    event AuctionStarted();
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event TokenWithdrawn();
    event RenterChanged(address indexed newRenter);

    function setUp() public {
        tokenContract = new ERC721Mintable("Test", "TNFT");
        vm.prank(tokenHolder);
        tokenContract.mint(tokenId);

        controllerObserver = new TestControllerObserver();
        controllerObserver.initialize(IRentalAuction(this), tokenHolder, abi.encode(tokenContract, tokenId));
    }

    function testOwnerIsCorrect() public {
        assertEq(controllerObserver.owner(), tokenHolder);
    }

    function testTransferOwnership() public {
        vm.prank(vm.addr(1));
        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        controllerObserver.transferOwnership(address(1));

        vm.prank(tokenHolder);
        vm.expectEmit(true, true, false, false);
        emit OwnershipTransferred(tokenHolder, address(1));
        controllerObserver.transferOwnership(address(1));

        assertEq(controllerObserver.owner(), address(1));
    }

    function testWithdrawToken() public {
        vm.startPrank(tokenHolder);

        // first transfer the nft into the contract
        tokenContract.transferFrom(tokenHolder, address(controllerObserver), tokenId);

        paused = false;
        vm.expectRevert(bytes4(keccak256("AuctionNotPaused()")));
        controllerObserver.withdrawToken();

        paused = true;
        vm.expectEmit(false, false, false, false);
        emit TokenWithdrawn();
        controllerObserver.withdrawToken();

        assertEq(tokenContract.ownerOf(tokenId), tokenHolder);

        vm.stopPrank();
    }

    function testStopAuction() external {
        pauseCount = 0;

        vm.prank(address(1));
        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        controllerObserver.stopAuction();

        vm.prank(tokenHolder);
        vm.expectEmit(false,false,false,false);
        emit AuctionStopped();
        controllerObserver.stopAuction();

        assertEq(pauseCount, 1);
    }

    function testStartAuction() external {
        unPauseCount = 0;

        vm.prank(address(1));
        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        controllerObserver.startAuction();


        // token not approved nor transferred
        vm.prank(tokenHolder);
        vm.expectRevert("ERC721: caller is not token owner or approved");
        controllerObserver.startAuction();

        uint256 snapshot = vm.snapshot();
        unPauseCount = 0;

        vm.startPrank(tokenHolder);
        // token is approved but not transferred
        tokenContract.approve(address(controllerObserver), tokenId);
        vm.expectEmit(false,false,false,false);
        emit AuctionStarted();
        controllerObserver.startAuction();
        assertEq(unPauseCount, 1);
        assertEq(tokenContract.ownerOf(tokenId), address(controllerObserver));

        // token is not approved but has already been transferred to controller
        vm.revertTo(snapshot);
        tokenContract.transferFrom(tokenHolder, address(controllerObserver), tokenId);
        vm.expectEmit(false,false,false,false);
        emit AuctionStarted();
        controllerObserver.startAuction();
        assertEq(unPauseCount, 1);
        assertEq(tokenContract.ownerOf(tokenId), address(controllerObserver));

        vm.stopPrank();
    }

    function testTokenInfoViewFunctions() public {
        assertEq(controllerObserver.underlyingTokenContract(), address(tokenContract));
        assertEq(controllerObserver.underlyingTokenID(), tokenId);
    }

    function testOnRenterChanged() public {
        vm.prank(tokenHolder);
        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        controllerObserver.onRenterChanged(address(1));

        vm.expectEmit(true,false,false,false);
        emit RenterChanged(address(1));
        controllerObserver.onRenterChanged(address(1));
    }

    uint256 pauseCount;
    uint256 unPauseCount;
    function pause() external override {
        pauseCount++;
    }
    function unpause() external override {
        unPauseCount++;
    }

    function currentRenter() external view override returns (address) {}
}
