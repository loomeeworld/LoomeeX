// SPDX-License-Identifier: Unlicensed
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./IMintNft.sol";
import "./MarketInfo.sol";

contract Exchange is IERC721Receiver, IERC1155Receiver, ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;

    uint256 public incentiveRate = 0;
    uint256 public minBidIncrement = 50000;
    uint256 public minBidDuration = 600;

    mapping(address => bool) public signers;
    mapping(bytes32 => MarketInfo.OrderInfo) public orderInfos;
    mapping(bytes32 => uint8) public orderStatus; // orderHash => STATUS_OPEN/STATUS_AUCTION/STATUS_DONE/STATUS_CANCEL

    constructor() {}

    event UpdateBids(uint256 minBidIncrement, uint256 minBidDuration);
    event UpdateSigner(address addr, bool isRemoval);
    event BidAuctionRefund(bytes32 indexed orderHash, IERC20 currency, address indexed user, uint256 amount);
    event CancelOrder(address indexed sender, bytes32 indexed orderHash);
    event OrderUpdate(uint256 op, address indexed seller, address buyer, IERC20 currency, uint256 price, address token,
        uint256 tokenId, uint256 tokenAmount, bytes32 indexed orderHash);

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return
        (interfaceId == type(IERC721Receiver).interfaceId) ||
    (interfaceId == type(IERC1155Receiver).interfaceId);
    }

    function cancelOrder(MarketInfo.Order memory order, uint256 bundleIndex) public nonReentrant whenNotPaused {
        require(order.user == msg.sender, "only cancel your own order");
        bytes32 orderHash = getOrderHash(order, order.bundle[bundleIndex]);
        if (orderStatus[orderHash] == MarketInfo.STATUS_OPEN) {
            orderStatus[orderHash] = MarketInfo.STATUS_CANCEL;
            emit CancelOrder(order.user, orderHash);
        }
    }

    function batchCancelOrders(MarketInfo.Order[] memory orders, uint256[] memory bundleIndexs) public nonReentrant whenNotPaused {
        require(orders.length == bundleIndexs.length, "param wrong");
        for (uint256 i = 0; i < orders.length; i++) {
            cancelOrder(orders[i], bundleIndexs[i]);
        }
    }

    // Buy sell orders placed by users
    function buy(
        MarketInfo.Order memory order,
        MarketInfo.Detail memory detail,
        bytes memory sigOrder,
        bytes memory sigDetail
    ) public payable nonReentrant whenNotPaused {
        uint256 ethBalanceBefore = address(this).balance - msg.value;
        _buy(order, detail, sigOrder, sigDetail);
        _transferEth(payable(msg.sender), address(this).balance - ethBalanceBefore);
    }

    function batchBuys(
        MarketInfo.Order[] memory orders,
        MarketInfo.Detail[] memory details,
        bytes[] memory sigOrders,
        bytes[] memory sigDetails
    ) public payable nonReentrant whenNotPaused {
        uint256 length = orders.length;
        require(length == details.length && length == sigOrders.length && length == sigDetails.length, "param wrong");
        uint256 ethBalanceBefore = address(this).balance - msg.value;
        for (uint256 i = 0; i < length; i++) {
            _buy(orders[i], details[i], sigOrders[i], sigDetails[i]);
        }
        _transferEth(payable(msg.sender), address(this).balance - ethBalanceBefore);
    }

    function _buy(
        MarketInfo.Order memory order,
        MarketInfo.Detail memory detail,
        bytes memory sigOrder,
        bytes memory sigDetail
    ) internal {
        (bytes32 orderHash, MarketInfo.TokenNFT memory tokenNft) = _validate(order, detail, sigOrder, sigDetail);
        require(detail.caller == msg.sender, "sender error");
        require(order.kind == MarketInfo.TYPE_SELL, "order.kind must be MarketInfo.TYPE_SELL");
        _deal(
            orderHash,
            order.user,  // seller
            tokenNft,
            order.currency,
            tokenNft.price,
            tokenNft.deadline,
            detail.caller,   // buyer
            detail.fee,
            order.network
        );
        emit OrderUpdate(
            1,
            order.user,
            detail.caller,
            order.currency,
            tokenNft.price,
            tokenNft.token,
            tokenNft.tokenId,
            tokenNft.amount,
            orderHash
        );
    }

    // Sell - match the user's make offer
    function sell(
        MarketInfo.Order memory order,
        MarketInfo.Detail memory detail,
        bytes memory sigOrder,
        bytes memory sigDetail
    ) public nonReentrant whenNotPaused {
        _sell(order, detail, sigOrder, sigDetail);
    }

    function _sell(
        MarketInfo.Order memory order,
        MarketInfo.Detail memory detail,
        bytes memory sigOrder,
        bytes memory sigDetail
    ) internal {
        (bytes32 orderHash, MarketInfo.TokenNFT memory tokenNft) = _validate(order, detail, sigOrder, sigDetail);
        require(detail.caller == msg.sender, "sender error");
        require(order.kind == MarketInfo.TYPE_BUY, "order.kind must be MarketInfo.TYPE_BUY");
        require(!_isZero(order.currency), "currency error");
        if (order.isMakeOfferCollection) {
            tokenNft.tokenId = detail.tokenId;
        }
        _deal(
            orderHash,
            detail.caller,  // seller
            tokenNft,
            order.currency,
            tokenNft.price,
            tokenNft.deadline,
            order.user,  // buyer
            detail.fee,
            order.network
        );
        emit OrderUpdate(
            2,
            detail.caller,
            order.user,
            order.currency,
            tokenNft.price,
            tokenNft.token,
            tokenNft.tokenId,
            tokenNft.amount,
            orderHash
        );
    }

    function _deal(
        bytes32 orderHash,
        address seller,
        MarketInfo.TokenNFT memory bundle,
        IERC20 currency,
        uint256 price,
        uint256 deadline,
        address buyer,
        MarketInfo.Fee memory fee,
        uint256 network
    ) internal {
        require(orderStatus[orderHash] == MarketInfo.STATUS_OPEN, "order state wrong");
        require(network == block.chainid, "wrong network");
        require(deadline > block.timestamp, "order timeout");
        _transferNFTs(bundle, seller, buyer, true);
        if (!_isZero(currency)) {
            currency.safeTransferFrom(buyer, address(this), price);
        }
        orderStatus[orderHash] = MarketInfo.STATUS_DONE;
        _finalProcessing(price, price, seller, currency, fee);
    }

    // Auction - Bid
    function bid(
        MarketInfo.Order memory order,
        MarketInfo.Detail memory detail,
        bytes memory sigOrder,
        bytes memory sigDetail
    ) public payable nonReentrant whenNotPaused {
        (bytes32 orderHash, MarketInfo.TokenNFT memory tokenNft) = _validate(order, detail, sigOrder, sigDetail);
        require(detail.caller == msg.sender, "sender error");
        require(order.kind == MarketInfo.TYPE_AUCTION, "order.kind must be MarketInfo.TYPE_AUCTION");
        require(orderStatus[orderHash] == MarketInfo.STATUS_OPEN || orderStatus[orderHash] == MarketInfo.STATUS_AUCTION, "order status error");
        _bid(
            orderHash,
            order.user,
            tokenNft,
            order.currency,
            tokenNft.price,
            tokenNft.deadline,
            detail.caller,
            detail.price,
            order.network
        );
        emit OrderUpdate(
            3,
            order.user,
            detail.caller,
            order.currency,
            tokenNft.price,
            tokenNft.token,
            tokenNft.tokenId,
            tokenNft.amount,
            orderHash
        );
    }

    function _bid(
        bytes32 orderHash,
        address seller,
        MarketInfo.TokenNFT memory bundle,
        IERC20 currency,
        uint256 startPrice,
        uint256 deadline,
        address buyer,
        uint256 price,
        uint256 network
    ) internal {
        require(network == block.chainid, "wrong network");
        require(incentiveRate < MarketInfo.RATE_BASE, "incentiveRate too large");
        if (_isZero(currency)) {
            require(price == msg.value, "price == msg.value");
        } else {
            currency.safeTransferFrom(buyer, address(this), price);
        }

        if (orderStatus[orderHash] == MarketInfo.STATUS_AUCTION) { // multiple bids
            MarketInfo.OrderInfo storage info = orderInfos[orderHash];
            require(info.seller == seller, "seller does not match");
            require(info.deadline > block.timestamp, "Bid ended");
            require(
                price >= info.price + ((info.price * minBidIncrement) / MarketInfo.RATE_BASE),
                "bid price too low"
            );

            uint256 incentive = (price * incentiveRate) / MarketInfo.RATE_BASE;
            _transferWithCurrency(currency, info.buyer, info.netPrice + incentive);
            emit BidAuctionRefund(orderHash, currency, info.buyer, info.netPrice + incentive);

            info.buyer = buyer;
            info.price = price;
            info.netPrice = price - incentive;
        } else { // first bid
            require(price >= startPrice, "bid lower than start price");
            require(deadline > block.timestamp, "auction ended");
            _transferNFTs(bundle, seller, address(this), true);
            orderStatus[orderHash] = MarketInfo.STATUS_AUCTION;
            orderInfos[orderHash] = MarketInfo.OrderInfo({
            seller: seller,
            buyer: buyer,
            currency: currency,
            price: price,
            netPrice: price,
            deadline: deadline,
            token: bundle.token,
            tokenId: bundle.tokenId,
            amount: bundle.amount,
            kind: bundle.kind,
            uri: bundle.uri
            });
        }
    }

    // Used to fulfill this order when the auction closes
    function completeBid(
        MarketInfo.Order memory order,
        MarketInfo.Detail memory detail,
        bytes memory sigOrder,
        bytes memory sigDetail
    ) public nonReentrant whenNotPaused {
        (bytes32 orderHash,) = _validate(order, detail, sigOrder, sigDetail);
        _completeBid(orderHash, detail.fee);
    }

    function _completeBid(bytes32 orderHash, MarketInfo.Fee memory fee) internal {
        require(orderInfos[orderHash].deadline < block.timestamp, "auction is not ended");
        _acceptBid(orderHash, fee);
    }

    // Order owner can accept current bid
    function acceptBid(
        MarketInfo.Order memory order,
        MarketInfo.Detail memory detail,
        bytes memory sigOrder,
        bytes memory sigDetail
    ) public nonReentrant whenNotPaused {
        (bytes32 orderHash,) = _validate(order, detail, sigOrder, sigDetail);
        require(detail.caller == msg.sender, "sender error");
        require(detail.caller == order.user, "only seller can call");
        _acceptBid(orderHash, detail.fee);
    }

    function _acceptBid(bytes32 orderHash, MarketInfo.Fee memory fee) internal {
        require(orderStatus[orderHash] == MarketInfo.STATUS_AUCTION, "order status error");
        orderStatus[orderHash] = MarketInfo.STATUS_DONE;
        MarketInfo.OrderInfo storage info = orderInfos[orderHash];
        MarketInfo.TokenNFT memory bundle = MarketInfo.TokenNFT({
        token: info.token,
        tokenId: info.tokenId,
        amount: info.amount,
        kind: info.kind,
        uri: info.uri,
        price: info.price,
        deadline: info.deadline
        });
        _transferNFTs(bundle, address(this), info.buyer, false);
        _finalProcessing(info.price, info.netPrice, info.seller, info.currency, fee);
        emit OrderUpdate(
            4,
            info.seller,
            info.buyer,
            info.currency,
            info.price,
            info.token,
            info.tokenId,
            info.amount,
            orderHash
        );
    }

    function _finalProcessing(
        uint256 price,
        uint256 netPrice,
        address seller,
        IERC20 currency,
        MarketInfo.Fee memory fee
    ) internal {
        uint256 feeAmount = (price * fee.feeRate) / MarketInfo.RATE_BASE;
        uint256 royaltyAmount = (price * fee.royaltyRate) / MarketInfo.RATE_BASE;
        uint256 sellerAmount = netPrice - feeAmount - royaltyAmount;
        _transferWithCurrency(currency, seller, sellerAmount);
        _transferWithCurrency(currency, fee.feeAddress, feeAmount);
        _transferWithCurrency(currency, fee.royaltyAddress, royaltyAmount);
    }

    function _transferWithCurrency(IERC20 currency, address to, uint256 amount) internal {
        if (amount == 0) {
            return;
        }
        require(to != address(0), "to cannot be address(0)");
        if (_isZero(currency)) {
            (bool success,) = payable(to).call{value: amount}("");
            require(success, "transfer eth failed");
        } else {
            currency.safeTransfer(to, amount);
        }
    }

    function _transferEth(address payable to, uint256 amount) internal {
        if (amount > 0) {
            require(to != address(0), "to cannot be address(0)");
            (bool success,) = to.call{value: amount}("");
            require(success, "transfer eth failed");
        }
    }

    function _transferNFTs(MarketInfo.TokenNFT memory p, address from, address to, bool flag) internal {
        if (p.kind == MarketInfo.TYPE_721) {
            IERC721(p.token).safeTransferFrom(from, to, p.tokenId);
        } else if (p.kind == MarketInfo.TYPE_1155) {
            IERC1155(p.token).safeTransferFrom(from, to, p.tokenId, p.amount, '');
        } else if (p.kind == MarketInfo.TYPE_MINT) {
            if (flag) {
                require(from != address(0) && from != address(this), "from error");
                IMintNft(p.token).mint(from, p.tokenId, p.uri);
            }
            IERC721(p.token).safeTransferFrom(from, to, p.tokenId);
        } else {
            revert("unsupported type");
        }
    }

    function _validate(
        MarketInfo.Order memory order,
        MarketInfo.Detail memory detail,
        bytes memory sigOrder,
        bytes memory sigDetail
    ) internal view returns (bytes32 orderHash, MarketInfo.TokenNFT memory tokenNft) {
        require(detail.txDeadline > block.timestamp, "Transaction timed out");
        require(signers[detail.signer], "unknown signer");
        verifyDetailSignature(detail, sigDetail, detail.signer);
        tokenNft = order.bundle[detail.bundleIndex];
        orderHash = getOrderHash(order, tokenNft);
        verifyOrderSignature(order, orderHash, detail.orderHash, sigOrder, order.user);
    }

    function verifyDetailSignature(
        MarketInfo.Detail memory detail,
        bytes memory sigDetail,
        address signer
    ) internal pure {
        require(verifySignature(sigDetail, keccak256(abi.encode(detail)), signer), "detail signature error");
    }

    function verifyOrderSignature(
        MarketInfo.Order memory order,
        bytes32 orderHash,
        bytes32 detailOrderHash,
        bytes memory sigOrder,
        address signer
    ) internal pure {
        require(orderHash == detailOrderHash, "order hash does not match");
        require(verifySignature(sigOrder, keccak256(abi.encode(order)), signer), "order signature error");
    }

    function verifySignature(bytes memory signature, bytes32 hash, address signer) public pure returns (bool) {
        return ECDSA.recover(ECDSA.toEthSignedMessageHash(hash), signature) == signer && signer != address(0);
    }

    function getOrderHash(MarketInfo.Order memory order, MarketInfo.TokenNFT memory tokenNft) internal pure returns (bytes32) {
        return
        keccak256(
            abi.encode(
                tokenNft,
                order.user,
                order.currency,
                order.salt,
                order.kind,
                order.isMakeOfferCollection,
                order.network
            )
        );
    }

    function _isZero(IERC20 currency) internal pure returns (bool) {
        return address(currency) == address(0);
    }

    function updateBids(uint256 minBidIncrement_, uint256 minBidDuration_) public onlyOwner {
        minBidIncrement = minBidIncrement_;
        minBidDuration = minBidDuration_;
        emit UpdateBids(minBidIncrement_, minBidDuration_);
    }

    function updateSigner(address addr, bool add) public onlyOwner {
        if (!add) {
            delete signers[addr];
        } else {
            signers[addr] = true;
        }
        emit UpdateSigner(addr, add);
    }

    function updateIncentiveRate(uint256 _incentiveRate) public onlyOwner {
        require(_incentiveRate < MarketInfo.RATE_BASE, "_incentiveRate too big");
        incentiveRate = _incentiveRate;
    }

    receive() external payable {}

    function pause() public onlyOwner {
        _pause();
    }

    function unpause() public onlyOwner {
        _unpause();
    }

    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes memory data
    ) external pure override returns (bytes4) {
        (operator);
        (from);
        (tokenId);
        (data);
        return this.onERC721Received.selector;
    }

    function onERC1155Received(
        address operator,
        address from,
        uint256 id,
        uint256 value,
        bytes memory data
    ) external pure override returns (bytes4) {
        (operator);
        (from);
        (id);
        (value);
        (data);
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address operator,
        address from,
        uint256[] memory ids,
        uint256[] memory values,
        bytes memory data
    ) external pure override returns (bytes4) {
        (operator);
        (from);
        (ids);
        (values);
        (data);
        return this.onERC1155BatchReceived.selector;
    }
}
