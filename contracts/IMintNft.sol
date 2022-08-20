// SPDX-License-Identifier: Unlicensed

pragma solidity ^0.8.13;

interface IMintNft {
    function mint(address to, uint256 tokenId, string memory uri) external;
}
