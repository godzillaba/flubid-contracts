// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import "superfluid-finance/contracts/apps/SuperTokenV1Library.sol";
import "superfluid-finance/contracts/interfaces/superfluid/ISuperToken.sol";

contract CreateStream is Script {
    using SuperTokenV1Library for ISuperToken;
    address recipient = 0x712A80A88C75668755394225D1c5564AbE71099d;
    ISuperToken maticx = ISuperToken(0x96B82B65ACF7072eFEb00502F45757F254c2a0D4);

    function setUp() external {}

    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        
        vm.startBroadcast(privateKey);

        maticx.createFlow(recipient, 100, abi.encode(address(0), bytes("hi")));

        vm.stopBroadcast();
    }
}