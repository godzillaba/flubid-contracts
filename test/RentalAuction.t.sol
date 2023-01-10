// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/Counter.sol";

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

import {IERC20} from "openzeppelin-contracts/interfaces/IERC20.sol";

contract RentalAuctionTest is Test {
    TestToken dai;
    ISuperToken daix;

    SuperfluidFrameworkDeployer.Framework sf;

    address bank = vm.addr(1);

    function setUp() public {
        SuperfluidFrameworkDeployer sfDeployer = new SuperfluidFrameworkDeployer();
        sf = sfDeployer.getFramework();
    
        (dai, daix) = sfDeployer.deployWrapperSuperToken(
            "Fake DAI", "DAI", 18, 100 ether
        );

        vm.prank(bank);
        dai.mint(bank, 100 ether);
    }

    function testFoo() public {}
}
