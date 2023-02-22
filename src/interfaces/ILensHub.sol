// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

interface ILensHub {
    struct PostData {
        uint256 profileId;
        string contentURI;
        address collectModule;
        bytes collectModuleInitData;
        address referenceModule;
        bytes referenceModuleInitData;
    }

    function post(PostData calldata vars) external returns (uint256);
}