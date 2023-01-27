// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { ERC4907 } from "./ERC4907.sol";
import { IERC721 } from "openzeppelin-contracts/interfaces/IERC721.sol";

contract ERC4907Wrapper is ERC4907 {
    IERC721 public immutable underlying;

    constructor(string memory name_, string memory symbol_, IERC721 underlying_) ERC4907(name_, symbol_) {
        underlying = underlying_;
    }

    function wrap(uint256 tokenId) external {
        _mint(msg.sender, tokenId);
        underlying.transferFrom(msg.sender, address(this), tokenId);
    }

    function unwrap(uint256 tokenId) external {
        require(_isApprovedOrOwner(msg.sender, tokenId), "ERC4907Wrapper: Not approved or owner");
        _burn(tokenId);
        underlying.transferFrom(address(this), msg.sender, tokenId);
    }
}