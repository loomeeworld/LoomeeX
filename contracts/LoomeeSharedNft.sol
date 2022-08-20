// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract LoomeeSharedNft is ERC721, Ownable, ReentrancyGuard {

    mapping(address => bool) public caller;
    mapping(uint256 => string) private _tokenURI;
    uint256 public curTokenId;
    uint256 public totalSupply;

    event MintByUri(address indexed caller, address indexed owner, uint256 tokenId, string uri);

    constructor(
        address _initCaller
    ) ERC721("LoomeeSharedNft", "LMSHR") {
        caller[_initCaller] = true;
    }

    function mint(address to, uint256 tokenId, string memory uri) public nonReentrant canCall {
        require(!_exists(tokenId), "tokenId has exist");
        _safeMint(to, tokenId);
        _tokenURI[tokenId] = uri;
        curTokenId = tokenId;

        totalSupply++;
        
        emit MintByUri(msg.sender, to, tokenId, uri);
    }

    function exists(uint256 tokenId) public view returns (bool) {
        return _exists(tokenId);
    }

    function tokenURI(uint256 tokenId) public view virtual override returns (string memory) {
        require(_exists(tokenId), "ERC721Metadata: URI query for nonexistent token");
        return _tokenURI[tokenId];
    }

    function addCaller(address _caller, bool _add) public onlyOwner {
        if (_add) {
            caller[_caller] = true;
        } else {
            delete caller[_caller];
        }
    }

    modifier canCall() {
        require(caller[msg.sender], "not caller");
        _;
    }

}
