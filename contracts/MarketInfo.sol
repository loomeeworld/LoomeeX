// SPDX-License-Identifier: Unlicensed

pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

library MarketInfo {
    
    uint256 public constant RATE_BASE = 1e6;
    uint8 public constant TYPE_SELL = 1;
    uint8 public constant TYPE_BUY = 2;
    uint8 public constant TYPE_AUCTION = 3;

    uint8 public constant STATUS_OPEN = 0;
    uint8 public constant STATUS_AUCTION = 1;
    uint8 public constant STATUS_DONE = 2;
    uint8 public constant STATUS_CANCEL = 3;

    uint8 public constant TYPE_721 = 1;
    uint8 public constant TYPE_1155 = 2;
    uint8 public constant TYPE_MINT = 3;

    struct OrderInfo {
        address seller;
        address buyer;
        IERC20 currency;
        uint256 price;
        uint256 netPrice;
        uint256 deadline;
        address token;
        uint256 tokenId;
        uint256 amount;
        uint8 kind; // NFT type 1 721, 2 1155， 3 mint
        string uri; // mint token uri
    }

    struct Order {
        TokenNFT[] bundle;
        address user;
        IERC20 currency;
        bytes32 salt;
        uint8 kind;
        bool isMakeOfferCollection; // true means a collection quote
        uint256 network;
    }

    struct TokenNFT {
        address token;
        uint256 tokenId;
        uint256 amount;
        uint8 kind; // NFT type 1 721, 2 1155， 3 mint
        string uri; // mint token uri
        uint256 price;
        uint256 deadline;
    }

    struct Detail {
        bytes32 orderHash;
        address signer; // The address of our platform's signature for detail
        uint256 txDeadline; // The validity period of this transaction is not set to pass 10000000000
        bytes32 salt;   // random number
        address caller; // the caller of this transaction
        uint256 price;  // price，This price is valid only at auction
        uint256 tokenId; // In an offer order, the value is valid when isMakeOfferCollection in the order is true
        uint256 bundleIndex; // Except for orders that are listed in batches, all others are 0
        Fee fee;    // cost
    }

    struct Fee {
        uint256 royaltyRate;    // Copyright fee, 50000 represents 5%
        address royaltyAddress; // The address where the copyright fee is collected
        uint256 feeRate;    // Transaction fee, 50000 represents 5%
        address feeAddress; // The address where the transaction fee is charged
    }

}
