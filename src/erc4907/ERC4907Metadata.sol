// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { ERC721 } from "openzeppelin-contracts/token/ERC721/ERC721.sol";
import { IERC721 } from "openzeppelin-contracts/interfaces/IERC721.sol";
import { IERC165 } from "openzeppelin-contracts/interfaces/IERC165.sol";
import { IERC721Metadata } from "openzeppelin-contracts/interfaces/IERC721Metadata.sol";
import { IERC4907, IERC4907Metadata } from "../interfaces/IERC4907Metadata.sol";

// https://eips.ethereum.org/EIPS/eip-4907

/// @title ERC4907Metadata
/// @notice A sample implementation of ERC4907Metadata
contract ERC4907Metadata is ERC721, IERC4907Metadata {
    struct UserInfo 
    {
        address user;   // address of user role
        uint64 expires; // unix timestamp, user expires
    }

    mapping (uint256  => UserInfo) internal _users;

    string public baseURI;

    constructor(string memory name_, string memory symbol_, string memory _baseURI) ERC721(name_, symbol_) {
        baseURI = _baseURI;
    }
    
    /// @notice set the user and expires of an NFT
    /// @dev The zero address indicates there is no user
    /// Throws if `tokenId` is not valid NFT
    /// @param user  The new user of the NFT
    /// @param expires  UNIX timestamp, The new user could use the NFT before expires
    function setUser(uint256 tokenId, address user, uint64 expires) public virtual{
        require(_isApprovedOrOwner(msg.sender, tokenId), "ERC4907: transfer caller is not owner nor approved");
        UserInfo storage info =  _users[tokenId];
        info.user = user;
        info.expires = expires;
        emit UpdateUser(tokenId, user, expires);
    }

    /// @notice Get the user address of an NFT
    /// @dev The zero address indicates that there is no user or the user is expired
    /// @param tokenId The NFT to get the user address for
    /// @return The user address for this NFT
    function userOf(uint256 tokenId) public view virtual returns(address){
        if( uint256(_users[tokenId].expires) >=  block.timestamp){
            return  _users[tokenId].user;
        }
        else{
            return address(0);
        }
    }

    /// @notice Get the user expires of an NFT
    /// @dev The zero value indicates that there is no user
    /// @param tokenId The NFT to get the user expires for
    /// @return The user expires for this NFT
    function userExpires(uint256 tokenId) public view virtual returns(uint256){
        return _users[tokenId].expires;
    }

    /// @dev See {IERC165-supportsInterface}.
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721, IERC165) returns (bool) {
        return 
            interfaceId == type(IERC4907).interfaceId 
            || interfaceId == type(IERC4907Metadata).interfaceId
            || interfaceId == type(IERC721Metadata).interfaceId
            || super.supportsInterface(interfaceId);
    }

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 tokenId,
        uint256
    ) internal virtual override {
        super._beforeTokenTransfer(from, to, tokenId, 0);

        if (from != to && _users[tokenId].user != address(0)) {
            delete _users[tokenId];
            emit UpdateUser(tokenId, address(0), 0);
        }
    }

    function mint(uint256 tokenId) external {
        _mint(msg.sender, tokenId);
    }

    function name() public view override(ERC721, IERC4907Metadata) returns (string memory) {
        return super.name();
    }

    function symbol() public view override(ERC721, IERC4907Metadata) returns (string memory) {
        return super.symbol();
    }
    
    function tokenURI(uint256) public view override(ERC721, IERC4907Metadata) returns (string memory) {
        return baseURI;
    }
} 