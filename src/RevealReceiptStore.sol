// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {FeeMath} from "./FeeMath.sol";

/// @title RevealReceiptStore
/// @notice Seller-first managed receipt contract for zkReveal Receipt Mode.
/// @dev Sellers create listings with opaque metadata commitments, buyers pay with seller-issued
/// purchase references, and settlement completes immediately with an on-chain receipt record.
contract RevealReceiptStore is EIP712, ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    string public constant EIP712_NAME = "RevealReceiptStore";
    string public constant EIP712_VERSION = "1";
    uint16 public constant MAX_PROTOCOL_FEE_BPS = 1_000;
    uint16 public constant MAX_INTEGRATOR_FEE_BPS = 1_000;
    /// @dev v1 purchase amount caps assume a 6-decimal settlement token such as USDC.
    uint256 public constant MIN_PURCHASE_AMOUNT = 1e6;
    uint256 public constant MAX_PURCHASE_AMOUNT = 5_000e6;
    uint64 public constant MAX_QUOTE_TTL = 24 hours;
    uint256 public constant MAX_LISTINGS_PER_SELLER = 50;
    uint256 public constant MAX_QUOTE_SIGNERS_PER_SELLER = 3;
    bytes32 public constant SIGNED_RECEIPT_QUOTE_TYPEHASH = keccak256(
        "SignedReceiptQuote(uint256 listingId,address seller,address buyer,bytes32 purchaseRef,uint256 amount,bytes32 metadataHash,address settlementToken,address integratorFeeRecipient,uint256 integratorFeeAmount,uint64 expiresAt)"
    );

    // -------------------------------------------------------------------------
    // Immutables
    // -------------------------------------------------------------------------

    IERC20 public immutable settlementToken;
    address public immutable feeRecipient;
    uint16 public immutable protocolFeeBps;

    // -------------------------------------------------------------------------
    // Structs
    // -------------------------------------------------------------------------

    struct Listing {
        address seller;
        bytes32 listingHash;
        uint256 unitPrice;
        bool active;
    }

    /// @dev Receipt Mode proof-of-payment record. Fulfillment meaning remains off-chain in seller systems.
    struct Receipt {
        bool exists;
        uint256 listingId;
        address seller;
        address buyer;
        uint256 amount;
        bytes32 purchaseRef;
        uint64 issuedAt;
    }

    /// @notice Seller-authorized dynamic checkout quote for a receipt purchase.
    /// @dev `seller` and `settlementToken` are derived by the contract but are still included in the
    ///      EIP-712 hash. The quote may be signed by the seller directly or by a seller-authorized
    ///      quote signer managed with `setQuoteSigner`. Authorized quote signers can sign dynamic
    ///      quotes for any listing owned by that seller. `purchaseRef` is an opaque seller-scoped
    ///      replay protection reference, `metadataHash` binds seller-defined off-chain checkout or
    ///      payment-link metadata, and `amount` is denominated in settlement token base units.
    ///      Integrator fee fields are optional, must be explicitly included in the seller-authorized
    ///      EIP-712 quote, and are paid from the gross `amount`; the seller receives `amount -
    ///      protocolFee - integratorFeeAmount`.
    struct SignedReceiptQuote {
        uint256 listingId;
        address buyer;
        bytes32 purchaseRef;
        uint256 amount;
        bytes32 metadataHash;
        address integratorFeeRecipient;
        uint256 integratorFeeAmount;
        uint64 expiresAt;
    }

    struct RakeQuote {
        uint256 grossAmount;
        uint256 protocolFee;
        uint256 integratorFee;
        uint256 sellerNet;
        address protocolFeeRecipient;
        address integratorFeeRecipient;
    }

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    uint256 public nextListingId = 1;
    uint256 public nextReceiptId = 1;

    mapping(uint256 => Listing) public listings;
    mapping(uint256 => Receipt) public receipts;
    mapping(address => uint256[]) public listingsBySeller;
    mapping(address => uint256[]) public receiptsByBuyer;
    mapping(address => uint256[]) public receiptsBySeller;
    mapping(address seller => mapping(address signer => bool)) public authorizedQuoteSigners;
    mapping(address seller => uint256 count) public authorizedQuoteSignerCount;
    /// @dev Seller-issued opaque `purchaseRef` values are generated off-chain and enforced as unique per seller.
    mapping(address => mapping(bytes32 => bool)) public purchaseRefUsed;
    /// @dev Deterministic seller-scoped reconciliation helper for off-chain generated refs. Returns 0 if unused.
    mapping(address => mapping(bytes32 => uint256)) public receiptIdBySellerAndPurchaseRef;

    bool public listingCreationPaused;
    bool public purchasesPaused;
    bool public quoteSignerUpdatesPaused;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event ListingCreated(
        uint256 indexed listingId, address indexed seller, bytes32 indexed listingHash, uint256 unitPrice
    );

    event ListingStatusChanged(uint256 indexed listingId, address indexed seller, bool active);

    event ListingPriceChanged(
        uint256 indexed listingId, address indexed seller, uint256 oldUnitPrice, uint256 newUnitPrice
    );

    event ReceiptPurchased(
        uint256 indexed receiptId,
        address indexed seller,
        bytes32 indexed purchaseRef,
        uint256 listingId,
        address buyer,
        uint256 amount,
        bytes32 metadataHash
    );

    event ProtocolFeePaid(
        uint256 indexed receiptId, uint256 indexed listingId, address indexed recipient, uint256 amount
    );

    event IntegratorFeePaid(
        uint256 indexed receiptId, uint256 indexed listingId, address indexed recipient, uint256 amount
    );

    event QuoteSignerAuthorizationChanged(address indexed seller, address indexed signer, bool authorized);
    event ListingCreationPauseChanged(bool paused);
    event PurchasesPauseChanged(bool paused);
    event QuoteSignerUpdatesPauseChanged(bool paused);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error ListingNotFound();
    error ReceiptNotFound();
    error NotListingSeller();
    error ListingInactive();
    error InvalidParams();
    error PurchaseRefAlreadyUsed();
    error QuoteExpired();
    error InvalidQuoteSigner();
    error QuoteBuyerMismatch();
    error IntegratorFeeTooHigh();
    error ListingCreationPaused();
    error PurchasesPaused();
    error QuoteSignerUpdatesPaused();
    error AmountOutOfBounds();
    error QuoteExpiryTooLong();
    error SellerListingLimitReached();
    error QuoteSignerLimitReached();

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier listingExists(uint256 listingId) {
        _listingExists(listingId);
        _;
    }

    modifier receiptExists(uint256 receiptId) {
        _receiptExists(receiptId);
        _;
    }

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(address settlementToken_, address feeRecipient_, uint16 protocolFeeBps_, address owner_)
        EIP712(EIP712_NAME, EIP712_VERSION)
        Ownable(_validateOwner(owner_))
    {
        if (settlementToken_ == address(0)) revert InvalidParams();
        if (protocolFeeBps_ > MAX_PROTOCOL_FEE_BPS) revert InvalidParams();
        if (protocolFeeBps_ > 0 && feeRecipient_ == address(0)) revert InvalidParams();

        settlementToken = IERC20(settlementToken_);
        feeRecipient = feeRecipient_;
        protocolFeeBps = protocolFeeBps_;
    }

    // -------------------------------------------------------------------------
    // Internal Helpers
    // -------------------------------------------------------------------------

    function _validateOwner(address owner_) internal pure returns (address validatedOwner) {
        if (owner_ == address(0)) revert InvalidParams();
        return owner_;
    }

    function _validatePurchaseAmount(uint256 amount) internal pure {
        if (amount < MIN_PURCHASE_AMOUNT || amount > MAX_PURCHASE_AMOUNT) {
            revert AmountOutOfBounds();
        }
    }

    function _quoteProtocolFee(uint256 grossAmount) internal view returns (uint256) {
        return grossAmount * protocolFeeBps / FeeMath.BPS_DENOMINATOR;
    }

    function _validateIntegratorFee(address recipient, uint256 integratorFeeAmount, uint256 grossAmount) internal pure {
        if (integratorFeeAmount == 0) {
            if (recipient != address(0)) revert InvalidParams();
            return;
        }

        if (recipient == address(0)) revert InvalidParams();

        uint256 maxIntegratorFee = grossAmount * MAX_INTEGRATOR_FEE_BPS / FeeMath.BPS_DENOMINATOR;
        if (integratorFeeAmount > maxIntegratorFee) revert IntegratorFeeTooHigh();
    }

    function _quoteRake(uint256 grossAmount, address integratorFeeRecipient, uint256 integratorFeeAmount)
        internal
        view
        returns (RakeQuote memory quote)
    {
        _validatePurchaseAmount(grossAmount);
        _validateIntegratorFee(integratorFeeRecipient, integratorFeeAmount, grossAmount);

        uint256 protocolFee = _quoteProtocolFee(grossAmount);
        if (protocolFee + integratorFeeAmount > grossAmount) revert InvalidParams();

        quote = RakeQuote({
            grossAmount: grossAmount,
            protocolFee: protocolFee,
            integratorFee: integratorFeeAmount,
            sellerNet: grossAmount - protocolFee - integratorFeeAmount,
            protocolFeeRecipient: feeRecipient,
            integratorFeeRecipient: integratorFeeRecipient
        });
    }

    function _distributeReceiptPurchaseProceeds(
        uint256 receiptId,
        uint256 listingId,
        address seller,
        uint256 amount,
        address integratorFeeRecipient,
        uint256 integratorFeeAmount
    ) internal {
        RakeQuote memory rake = _quoteRake(amount, integratorFeeRecipient, integratorFeeAmount);

        if (rake.protocolFee > 0) {
            settlementToken.safeTransfer(rake.protocolFeeRecipient, rake.protocolFee);
            emit ProtocolFeePaid(receiptId, listingId, rake.protocolFeeRecipient, rake.protocolFee);
        }

        if (rake.integratorFee > 0) {
            settlementToken.safeTransfer(rake.integratorFeeRecipient, rake.integratorFee);
            emit IntegratorFeePaid(receiptId, listingId, rake.integratorFeeRecipient, rake.integratorFee);
        }

        settlementToken.safeTransfer(seller, rake.sellerNet);
    }

    function _hashSignedReceiptQuote(SignedReceiptQuote calldata quote, address seller)
        internal
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    SIGNED_RECEIPT_QUOTE_TYPEHASH,
                    quote.listingId,
                    seller,
                    quote.buyer,
                    quote.purchaseRef,
                    quote.amount,
                    quote.metadataHash,
                    address(settlementToken),
                    quote.integratorFeeRecipient,
                    quote.integratorFeeAmount,
                    quote.expiresAt
                )
            )
        );
    }

    function _listingExists(uint256 listingId) internal view {
        if (listings[listingId].seller == address(0)) revert ListingNotFound();
    }

    function _receiptExists(uint256 receiptId) internal view {
        if (!receipts[receiptId].exists) revert ReceiptNotFound();
    }

    function _onlyListingSeller(uint256 listingId) internal view {
        if (listings[listingId].seller != msg.sender) revert NotListingSeller();
    }

    function _verifySignedReceiptQuote(
        SignedReceiptQuote calldata quote,
        bytes calldata sellerSignature,
        address expectedBuyer
    ) internal view returns (Listing storage listing) {
        listing = listings[quote.listingId];

        if (!listing.active) revert ListingInactive();
        if (quote.buyer != expectedBuyer) revert QuoteBuyerMismatch();
        if (quote.purchaseRef == bytes32(0)) revert InvalidParams();
        if (quote.metadataHash == bytes32(0)) revert InvalidParams();
        _validatePurchaseAmount(quote.amount);
        _validateIntegratorFee(quote.integratorFeeRecipient, quote.integratorFeeAmount, quote.amount);
        if (quote.expiresAt <= block.timestamp) revert QuoteExpired();
        if (quote.expiresAt > block.timestamp + MAX_QUOTE_TTL) revert QuoteExpiryTooLong();
        if (purchaseRefUsed[listing.seller][quote.purchaseRef]) revert PurchaseRefAlreadyUsed();

        bytes32 digest = _hashSignedReceiptQuote(quote, listing.seller);
        address signer = ECDSA.recover(digest, sellerSignature);
        if (signer != listing.seller && !authorizedQuoteSigners[listing.seller][signer]) {
            revert InvalidQuoteSigner();
        }
    }

    /// @dev `payer` provides the settlement token. `receiptBuyer` is the buyer recorded on-chain.
    ///      In direct v1 purchases both are `msg.sender`; future adapter flows may split them.
    function _settleReceiptPurchase(
        uint256 listingId,
        address seller,
        address payer,
        address receiptBuyer,
        uint256 amount,
        bytes32 purchaseRef,
        bytes32 metadataHash,
        address integratorFeeRecipient,
        uint256 integratorFeeAmount
    ) internal returns (uint256 receiptId) {
        settlementToken.safeTransferFrom(payer, address(this), amount);

        purchaseRefUsed[seller][purchaseRef] = true;

        receiptId = nextReceiptId++;

        Receipt storage receipt = receipts[receiptId];
        receipt.exists = true;
        receipt.listingId = listingId;
        receipt.seller = seller;
        receipt.buyer = receiptBuyer;
        receipt.amount = amount;
        receipt.purchaseRef = purchaseRef;
        receipt.issuedAt = uint64(block.timestamp);

        receiptsByBuyer[receiptBuyer].push(receiptId);
        receiptsBySeller[seller].push(receiptId);
        receiptIdBySellerAndPurchaseRef[seller][purchaseRef] = receiptId;

        _distributeReceiptPurchaseProceeds(
            receiptId, listingId, seller, amount, integratorFeeRecipient, integratorFeeAmount
        );

        emit ReceiptPurchased(receiptId, seller, purchaseRef, listingId, receiptBuyer, amount, metadataHash);
    }

    // -------------------------------------------------------------------------
    // Seller Configuration Functions
    // -------------------------------------------------------------------------

    /// @notice Authorize or revoke a signer that can create dynamic receipt quotes for the caller's listings.
    /// @dev Authorized quote signers can sign dynamic receipt quotes for any listing owned by `msg.sender`.
    function setQuoteSigner(address signer, bool authorized) external {
        if (quoteSignerUpdatesPaused) revert QuoteSignerUpdatesPaused();
        if (signer == address(0)) revert InvalidParams();
        if (signer == msg.sender) revert InvalidParams();
        bool currentlyAuthorized = authorizedQuoteSigners[msg.sender][signer];
        if (authorized == currentlyAuthorized) {
            emit QuoteSignerAuthorizationChanged(msg.sender, signer, authorized);
            return;
        }

        if (authorized) {
            if (authorizedQuoteSignerCount[msg.sender] >= MAX_QUOTE_SIGNERS_PER_SELLER) {
                revert QuoteSignerLimitReached();
            }
            authorizedQuoteSignerCount[msg.sender]++;
        } else {
            authorizedQuoteSignerCount[msg.sender]--;
        }

        authorizedQuoteSigners[msg.sender][signer] = authorized;

        emit QuoteSignerAuthorizationChanged(msg.sender, signer, authorized);
    }

    // -------------------------------------------------------------------------
    // Admin Safety Functions
    // -------------------------------------------------------------------------

    function setListingCreationPaused(bool paused) external onlyOwner {
        listingCreationPaused = paused;
        emit ListingCreationPauseChanged(paused);
    }

    function setPurchasesPaused(bool paused) external onlyOwner {
        purchasesPaused = paused;
        emit PurchasesPauseChanged(paused);
    }

    function setQuoteSignerUpdatesPaused(bool paused) external onlyOwner {
        quoteSignerUpdatesPaused = paused;
        emit QuoteSignerUpdatesPauseChanged(paused);
    }

    // -------------------------------------------------------------------------
    // Seller Listing Functions
    // -------------------------------------------------------------------------

    /// @notice Create a seller-owned listing for Receipt Mode purchases.
    /// @dev `listingHash` is an opaque seller-defined metadata commitment. Human-readable product
    ///      data lives off-chain, for example inside a seller-signed payment link. `unitPrice` is
    ///      denominated in settlement token base units.
    function createListing(bytes32 listingHash, uint256 unitPrice) external returns (uint256 listingId) {
        if (listingCreationPaused) revert ListingCreationPaused();
        if (listingHash == bytes32(0)) revert InvalidParams();
        _validatePurchaseAmount(unitPrice);
        if (listingsBySeller[msg.sender].length >= MAX_LISTINGS_PER_SELLER) {
            revert SellerListingLimitReached();
        }

        listingId = nextListingId++;

        Listing storage listing = listings[listingId];
        listing.seller = msg.sender;
        listing.listingHash = listingHash;
        listing.unitPrice = unitPrice;
        listing.active = true;

        listingsBySeller[msg.sender].push(listingId);

        emit ListingCreated(listingId, msg.sender, listingHash, unitPrice);
    }

    /// @notice Update the active status of a seller-owned listing.
    function setListingActive(uint256 listingId, bool active) external listingExists(listingId) {
        _onlyListingSeller(listingId);
        listings[listingId].active = active;
        emit ListingStatusChanged(listingId, msg.sender, active);
    }

    /// @notice Update the default fixed listing price of a seller-owned listing.
    /// @dev `newUnitPrice` is denominated in settlement token base units.
    ///      Signed receipt quotes may use custom amounts independent of `listing.unitPrice`.
    function setListingPrice(uint256 listingId, uint256 newUnitPrice) external listingExists(listingId) {
        _onlyListingSeller(listingId);
        _validatePurchaseAmount(newUnitPrice);

        Listing storage listing = listings[listingId];
        uint256 oldUnitPrice = listing.unitPrice;
        listing.unitPrice = newUnitPrice;

        emit ListingPriceChanged(listingId, msg.sender, oldUnitPrice, newUnitPrice);
    }

    // -------------------------------------------------------------------------
    // Purchase Functions
    // -------------------------------------------------------------------------

    /// @notice Purchase a Receipt Mode listing using a seller-issued off-chain purchase reference.
    /// @dev `purchaseRef` is expected to be a hash or other opaque seller-scoped purchase intent
    ///      reference and must be unique per seller. Payment settles immediately and fulfillment
    ///      remains entirely off-chain in seller systems.
    function purchaseReceipt(uint256 listingId, bytes32 purchaseRef)
        external
        nonReentrant
        listingExists(listingId)
        returns (uint256 receiptId)
    {
        if (purchasesPaused) revert PurchasesPaused();
        Listing storage listing = listings[listingId];

        if (!listing.active) revert ListingInactive();
        if (purchaseRef == bytes32(0)) revert InvalidParams();
        if (purchaseRefUsed[listing.seller][purchaseRef]) revert PurchaseRefAlreadyUsed();

        return _settleReceiptPurchase(
            listingId, listing.seller, msg.sender, msg.sender, listing.unitPrice, purchaseRef, bytes32(0), address(0), 0
        );
    }

    /// @notice Purchase a Receipt Mode listing using a seller-authorized EIP-712 quote.
    /// @dev The signed amount overrides the current listing unit price and settles immediately on success.
    ///      Quotes are valid only while `block.timestamp < quote.expiresAt`.
    ///      The recovered signer must be the listing seller or a signer authorized by the seller.
    ///      The signed quote may also include an optional integrator fee paid from the gross amount.
    function purchaseSignedReceipt(SignedReceiptQuote calldata quote, bytes calldata sellerSignature)
        external
        nonReentrant
        listingExists(quote.listingId)
        returns (uint256 receiptId)
    {
        if (purchasesPaused) revert PurchasesPaused();
        Listing storage listing = _verifySignedReceiptQuote(quote, sellerSignature, msg.sender);

        return _settleReceiptPurchase(
            quote.listingId,
            listing.seller,
            msg.sender,
            msg.sender,
            quote.amount,
            quote.purchaseRef,
            quote.metadataHash,
            quote.integratorFeeRecipient,
            quote.integratorFeeAmount
        );
    }

    // -------------------------------------------------------------------------
    // Preview / Hash Functions
    // -------------------------------------------------------------------------

    /// @notice Quote gross amount, protocol fee, seller net, and fee recipient for a receipt purchase.
    function quotePurchaseReceipt(uint256 listingId)
        external
        view
        listingExists(listingId)
        returns (uint256 grossAmount, uint256 protocolFee, uint256 sellerNet, address quotedFeeRecipient)
    {
        Listing storage listing = listings[listingId];
        RakeQuote memory rake = _quoteRake(listing.unitPrice, address(0), 0);
        grossAmount = rake.grossAmount;
        protocolFee = rake.protocolFee;
        sellerNet = rake.sellerNet;
        quotedFeeRecipient = rake.protocolFeeRecipient;
    }

    /// @notice Returns the EIP-712 digest for a seller-authorized signed receipt quote.
    /// @dev The digest includes the derived seller, settlement token, current chain ID, and this contract address.
    ///      It may be signed by the listing seller or by a quote signer authorized by that seller.
    function hashSignedReceiptQuote(SignedReceiptQuote calldata quote)
        public
        view
        listingExists(quote.listingId)
        returns (bytes32)
    {
        Listing storage listing = listings[quote.listingId];
        return _hashSignedReceiptQuote(quote, listing.seller);
    }

    /// @notice Preview gross amount, protocol fee, integrator fee, seller net, fee recipients,
    /// seller, and listingHash for a signed quote.
    /// @dev This performs fee math only. It does not verify the seller signature, buyer match, quote expiry,
    ///      listing active status, or purchaseRef replay status. `listingHash` is an opaque
    ///      seller-defined metadata commitment; human-readable product data remains off-chain.
    function previewSignedReceiptPurchase(SignedReceiptQuote calldata quote)
        external
        view
        listingExists(quote.listingId)
        returns (
            uint256 grossAmount,
            uint256 protocolFee,
            uint256 integratorFee,
            uint256 sellerNet,
            address quotedFeeRecipient,
            address integratorFeeRecipient,
            address seller,
            bytes32 listingHash
        )
    {
        Listing storage listing = listings[quote.listingId];
        if (quote.purchaseRef == bytes32(0)) revert InvalidParams();
        if (quote.metadataHash == bytes32(0)) revert InvalidParams();
        RakeQuote memory rake = _quoteRake(quote.amount, quote.integratorFeeRecipient, quote.integratorFeeAmount);

        grossAmount = rake.grossAmount;
        protocolFee = rake.protocolFee;
        integratorFee = rake.integratorFee;
        sellerNet = rake.sellerNet;
        quotedFeeRecipient = rake.protocolFeeRecipient;
        integratorFeeRecipient = rake.integratorFeeRecipient;
        seller = listing.seller;
        listingHash = listing.listingHash;
    }

    // -------------------------------------------------------------------------
    // Getters
    // -------------------------------------------------------------------------

    function getListingsBySeller(address seller) external view returns (uint256[] memory) {
        return listingsBySeller[seller];
    }

    function getReceiptsByBuyer(address buyer) external view returns (uint256[] memory) {
        return receiptsByBuyer[buyer];
    }

    function getReceiptsBySeller(address seller) external view returns (uint256[] memory) {
        return receiptsBySeller[seller];
    }

    function getListing(uint256 listingId) external view listingExists(listingId) returns (Listing memory) {
        return listings[listingId];
    }

    function getReceipt(uint256 receiptId) external view receiptExists(receiptId) returns (Receipt memory) {
        return receipts[receiptId];
    }

    function getReceiptIdBySellerAndPurchaseRef(address seller, bytes32 purchaseRef) external view returns (uint256) {
        return receiptIdBySellerAndPurchaseRef[seller][purchaseRef];
    }
}
