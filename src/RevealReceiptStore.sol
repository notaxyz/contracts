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
import {PurchaseRefRegistry} from "./PurchaseRefRegistry.sol";

/// @title RevealReceiptStore
/// @notice Seller-first managed receipt contract for zkReveal Receipt Mode.
/// @dev Sellers create listings with opaque metadata commitments, buyers pay with protocol-scoped
/// `purchaseRef` hashes derived from off-chain raw purchase references, and settlement completes
/// immediately with an on-chain receipt record. Replay protection is enforced canonically through
/// a shared `PurchaseRefRegistry`, while this contract keeps deterministic seller-side purchase
/// reconciliation on-chain. Listing and receipt discovery is expected to be handled from events by
/// indexers or seller systems.
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
    ///      `1e6` means 1 USDC when the settlement token uses 6 decimals.
    uint256 public constant MIN_PURCHASE_AMOUNT = 1e6;
    /// @dev v1 purchase amount caps assume a 6-decimal settlement token such as USDC.
    ///      `5_000e6` means 5,000 USDC when the settlement token uses 6 decimals.
    uint256 public constant MAX_PURCHASE_AMOUNT = 5_000e6;
    uint64 public constant MAX_QUOTE_TTL = 24 hours;
    uint256 public constant MAX_LISTINGS_PER_SELLER = 50;
    uint256 public constant MAX_QUOTE_SIGNERS_PER_SELLER = 3;
    string internal constant PURCHASE_REF_HASH_DOMAIN = "zkReveal.purchaseRef.receipt.v1";
    uint256 internal constant MAX_RAW_PURCHASE_REF_LENGTH = 128;
    bytes32 public constant SIGNED_RECEIPT_QUOTE_TYPEHASH = keccak256(
        "SignedReceiptQuote(uint256 listingId,address seller,address buyer,bytes32 purchaseRef,uint256 amount,bytes32 metadataHash,address settlementToken,address purchaseRefRegistry,address integratorFeeRecipient,uint256 integratorFeeAmount,uint64 expiresAt)"
    );

    // -------------------------------------------------------------------------
    // Immutables
    // -------------------------------------------------------------------------

    /// @notice Settlement token used for all v1 purchases.
    /// @dev Official v1 deployments are intended for 6-decimal tokens such as USDC.
    ///      `MIN_PURCHASE_AMOUNT` and `MAX_PURCHASE_AMOUNT` assume 6 decimals.
    ///      The constructor does not inspect token decimals.
    IERC20 public immutable settlementToken;
    /// @notice Canonical protocol-level replay protection registry shared across settlement stores.
    PurchaseRefRegistry public immutable purchaseRefRegistry;
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

    /// @dev Receipt Mode proof-of-payment record. Fulfillment meaning remains off-chain in seller
    ///      systems. Receipt discovery is expected to come from events or indexers.
    struct Receipt {
        uint256 listingId;
        address seller;
        address buyer;
        uint256 amount;
        bytes32 purchaseRef;
        uint64 issuedAt;
    }

    /// @notice Seller-authorized EIP-712 quote for a buyer-bound receipt purchase.
    /// @dev The signed digest binds the listing seller, `listingId`, `buyer`, `purchaseRef`,
    ///      `amount`, `metadataHash`, the v1 `settlementToken`, the immutable
    ///      `purchaseRefRegistry`, optional integrator fee fields, `expiresAt`,
    ///      `block.chainid`, and `address(this)`. `buyer` must match `msg.sender` during
    ///      `purchaseSignedReceipt`, so another wallet cannot consume the same quote. The quote
    ///      may be signed by the seller directly or by a signer authorized with `setQuoteSigner`.
    ///      Authorization is seller-wide in v1, so an authorized quote signer can sign quotes for
    ///      any listing owned by that seller. `purchaseRef` is a protocol-scoped hash of an
    ///      off-chain raw purchase reference that is consumed through `PurchaseRefRegistry`,
    ///      `metadataHash` binds seller-defined off-chain checkout or payment-link metadata, and
    ///      `amount` is denominated in settlement token base units. Integrator fee fields are
    ///      optional, must be explicitly included in the seller-authorized quote, and are paid
    ///      from the gross `amount`; the seller receives
    ///      `amount - protocolFee - integratorFeeAmount`.
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

    struct SignedReceiptPurchaseValidation {
        uint256 grossAmount;
        uint256 protocolFee;
        uint256 integratorFee;
        uint256 sellerNet;
        address protocolFeeRecipient;
        address integratorFeeRecipient;
        address seller;
        bytes32 listingHash;
        address recoveredSigner;
    }

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    uint256 public nextListingId = 1;
    uint256 public nextReceiptId = 1;

    mapping(uint256 => Listing) public listings;
    mapping(uint256 => Receipt) public receipts;
    /// @dev Enforces `MAX_LISTINGS_PER_SELLER`. Listing discovery is expected to come from
    ///      `ListingCreated` events or indexers, not on-chain enumeration.
    mapping(address seller => uint256 count) public listingCountBySeller;
    /// @dev Seller-wide quote signer authorization.
    ///      `authorizedQuoteSigners[seller][signer] = true` means `signer` may sign
    ///      `SignedReceiptQuote` values for any listing owned by `seller`.
    mapping(address seller => mapping(address signer => bool)) public authorizedQuoteSigners;
    /// @dev Number of currently authorized seller-wide quote signers for each seller.
    mapping(address seller => uint256 count) public authorizedQuoteSignerCount;
    /// @dev Deterministic seller-scoped reconciliation helper for `purchaseRef` hashes derived
    ///      from off-chain `rawPurchaseRef` values. Canonical replay protection lives in
    ///      `purchaseRefRegistry`; this mapping is retained only for seller and indexer receipt
    ///      lookup after settlement and returns 0 if no matching receipt has been recorded here.
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
        address indexed buyer,
        uint256 listingId,
        bytes32 purchaseRef,
        uint256 amount,
        bytes32 metadataHash
    );

    event ProtocolFeePaid(
        uint256 indexed receiptId, uint256 indexed listingId, address indexed recipient, uint256 amount
    );

    event IntegratorFeePaid(
        uint256 indexed receiptId, uint256 indexed listingId, address indexed recipient, uint256 amount
    );

    event SellerPaid(uint256 indexed receiptId, uint256 indexed listingId, address indexed seller, uint256 amount);

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
    error InvalidPurchaseRef();
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

    /// @notice Deploy a v1 receipt store with a fixed settlement token and protocol fee model.
    /// @dev Official v1 deployments are intended for 6-decimal settlement tokens such as USDC.
    ///      The constructor validates only address and fee bounds and does not inspect token
    ///      decimals.
    constructor(
        address settlementToken_,
        address purchaseRefRegistry_,
        address feeRecipient_,
        uint16 protocolFeeBps_,
        address owner_
    ) EIP712(EIP712_NAME, EIP712_VERSION) Ownable(_validateOwner(owner_)) {
        if (settlementToken_ == address(0)) revert InvalidParams();
        if (purchaseRefRegistry_ == address(0)) revert InvalidParams();
        if (protocolFeeBps_ > MAX_PROTOCOL_FEE_BPS) revert InvalidParams();
        if (protocolFeeBps_ > 0 && feeRecipient_ == address(0)) revert InvalidParams();

        settlementToken = IERC20(settlementToken_);
        purchaseRefRegistry = PurchaseRefRegistry(purchaseRefRegistry_);
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

    function _validateRawPurchaseRef(string calldata rawPurchaseRef) internal pure {
        uint256 rawPurchaseRefLength = bytes(rawPurchaseRef).length;
        if (rawPurchaseRefLength == 0 || rawPurchaseRefLength > MAX_RAW_PURCHASE_REF_LENGTH) {
            revert InvalidPurchaseRef();
        }
    }

    function _validatePurchaseRef(bytes32 purchaseRef) internal pure {
        if (purchaseRef == bytes32(0)) revert InvalidPurchaseRef();
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
        RakeQuote memory rake
    ) internal {
        if (rake.protocolFee > 0) {
            settlementToken.safeTransfer(rake.protocolFeeRecipient, rake.protocolFee);
            emit ProtocolFeePaid(receiptId, listingId, rake.protocolFeeRecipient, rake.protocolFee);
        }

        if (rake.integratorFee > 0) {
            settlementToken.safeTransfer(rake.integratorFeeRecipient, rake.integratorFee);
            emit IntegratorFeePaid(receiptId, listingId, rake.integratorFeeRecipient, rake.integratorFee);
        }

        settlementToken.safeTransfer(seller, rake.sellerNet);
        emit SellerPaid(receiptId, listingId, seller, rake.sellerNet);
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
                    address(purchaseRefRegistry),
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
        if (receipts[receiptId].seller == address(0)) revert ReceiptNotFound();
    }

    function _onlyListingSeller(uint256 listingId) internal view {
        if (listings[listingId].seller != msg.sender) revert NotListingSeller();
    }

    function _verifySignedReceiptQuoteWithSigner(
        SignedReceiptQuote calldata quote,
        bytes calldata sellerSignature,
        address expectedBuyer
    ) internal view returns (Listing storage listing, address signer) {
        listing = listings[quote.listingId];

        if (!listing.active) revert ListingInactive();
        if (quote.buyer != expectedBuyer) revert QuoteBuyerMismatch();
        _validatePurchaseRef(quote.purchaseRef);
        if (quote.metadataHash == bytes32(0)) revert InvalidParams();
        _validatePurchaseAmount(quote.amount);
        _validateIntegratorFee(quote.integratorFeeRecipient, quote.integratorFeeAmount, quote.amount);
        if (quote.expiresAt <= block.timestamp) revert QuoteExpired();
        if (quote.expiresAt > block.timestamp + MAX_QUOTE_TTL) revert QuoteExpiryTooLong();
        if (purchaseRefRegistry.isConsumed(quote.purchaseRef)) {
            revert PurchaseRefAlreadyUsed();
        }

        bytes32 digest = _hashSignedReceiptQuote(quote, listing.seller);
        signer = ECDSA.recover(digest, sellerSignature);
        if (signer != listing.seller && !authorizedQuoteSigners[listing.seller][signer]) {
            revert InvalidQuoteSigner();
        }
    }

    function _verifySignedReceiptQuote(
        SignedReceiptQuote calldata quote,
        bytes calldata sellerSignature,
        address expectedBuyer
    ) internal view returns (Listing storage listing) {
        (listing,) = _verifySignedReceiptQuoteWithSigner(quote, sellerSignature, expectedBuyer);
    }

    function _validateSignedReceiptPurchaseView(
        SignedReceiptQuote calldata quote,
        bytes calldata sellerSignature,
        address expectedBuyer
    ) internal view returns (SignedReceiptPurchaseValidation memory validation) {
        (Listing storage listing, address signer) =
            _verifySignedReceiptQuoteWithSigner(quote, sellerSignature, expectedBuyer);
        RakeQuote memory rake = _quoteRake(quote.amount, quote.integratorFeeRecipient, quote.integratorFeeAmount);

        validation.grossAmount = rake.grossAmount;
        validation.protocolFee = rake.protocolFee;
        validation.integratorFee = rake.integratorFee;
        validation.sellerNet = rake.sellerNet;
        validation.protocolFeeRecipient = rake.protocolFeeRecipient;
        validation.integratorFeeRecipient = rake.integratorFeeRecipient;
        validation.seller = listing.seller;
        validation.listingHash = listing.listingHash;
        validation.recoveredSigner = signer;
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
        RakeQuote memory rake = _quoteRake(amount, integratorFeeRecipient, integratorFeeAmount);

        purchaseRefRegistry.consume(purchaseRef);
        settlementToken.safeTransferFrom(payer, address(this), amount);

        receiptId = nextReceiptId++;

        Receipt storage receipt = receipts[receiptId];
        receipt.listingId = listingId;
        receipt.seller = seller;
        receipt.buyer = receiptBuyer;
        receipt.amount = amount;
        receipt.purchaseRef = purchaseRef;
        receipt.issuedAt = uint64(block.timestamp);

        receiptIdBySellerAndPurchaseRef[seller][purchaseRef] = receiptId;

        _distributeReceiptPurchaseProceeds(receiptId, listingId, seller, rake);

        emit ReceiptPurchased(receiptId, seller, receiptBuyer, listingId, purchaseRef, amount, metadataHash);
    }

    // -------------------------------------------------------------------------
    // Seller Configuration Functions
    // -------------------------------------------------------------------------

    /// @notice Authorize or revoke a seller-wide signer for `msg.sender`'s dynamic receipt quotes.
    /// @dev When authorized, `signer` can sign `SignedReceiptQuote` values for any listing owned
    ///      by `msg.sender`, not just one listing. Treat authorized signers as hot operational
    ///      keys and revoke compromised signers immediately with `setQuoteSigner(signer, false)`.
    ///      v1 signer scope is seller-wide, not per listing.
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
        if (listingCountBySeller[msg.sender] >= MAX_LISTINGS_PER_SELLER) {
            revert SellerListingLimitReached();
        }

        listingId = nextListingId++;

        Listing storage listing = listings[listingId];
        listing.seller = msg.sender;
        listing.listingHash = listingHash;
        listing.unitPrice = unitPrice;
        listing.active = true;

        listingCountBySeller[msg.sender]++;

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

    /// @notice Purchase a public fixed-price Receipt Mode listing using a protocol-scoped `purchaseRef` hash.
    /// @dev This is the simple public purchase path. It uses the listing's current `unitPrice`,
    ///      is not buyer-bound before submission, and records `msg.sender` as the buyer. Any
    ///      wallet that submits a valid unconsumed `purchaseRef` first and pays first receives the
    ///      receipt. `purchaseRef` should normally be the output of
    ///      `hashPurchaseRef(seller, listingId, rawPurchaseRef)`, where `rawPurchaseRef` remains
    ///      off-chain in the seller, bot, or backend system. That readable raw reference can later
    ///      be revealed or reused for support, reconciliation, buyer proof, or seller accounting.
    ///      `purchaseRef` is a protocol-scoped hash consumed through `PurchaseRefRegistry`,
    ///      preventing replay across current and future zkReveal settlement contracts that share
    ///      the registry. Use `purchaseSignedReceipt` instead for buyer-bound payment links,
    ///      private checkout flows, dynamic pricing, or integrator fees. Payment settles
    ///      immediately and fulfillment remains entirely off-chain in seller systems. Receipt
    ///      discovery is expected to be handled from `ReceiptPurchased` events or indexers.
    function purchaseReceipt(uint256 listingId, bytes32 purchaseRef)
        external
        nonReentrant
        listingExists(listingId)
        returns (uint256 receiptId)
    {
        if (purchasesPaused) revert PurchasesPaused();
        Listing storage listing = listings[listingId];

        if (!listing.active) revert ListingInactive();
        _validatePurchaseRef(purchaseRef);
        if (purchaseRefRegistry.isConsumed(purchaseRef)) {
            revert PurchaseRefAlreadyUsed();
        }

        return _settleReceiptPurchase(
            listingId, listing.seller, msg.sender, msg.sender, listing.unitPrice, purchaseRef, bytes32(0), address(0), 0
        );
    }

    /// @notice Purchase a Receipt Mode listing using a seller-authorized EIP-712 quote.
    /// @dev This is the recommended v1 flow for production checkout and payment-link integrations.
    ///      Seller Payment Link Mode uses a quote signed by the listing seller or an authorized
    ///      seller-wide quote signer, with `quote.purchaseRef` carrying the protocol-scoped hash
    ///      derived from an off-chain `rawPurchaseRef`. The signed quote binds the buyer, seller,
    ///      listing, `purchaseRef`, amount, metadata, settlement token, `purchaseRefRegistry`,
    ///      expiry, chain, and contract. The signed amount overrides the current listing unit
    ///      price and settles immediately on success. The shared `PurchaseRefRegistry` is the
    ///      canonical replay protection layer across settlement contracts.
    ///      Quotes are valid only while `block.timestamp < quote.expiresAt`, and `quote.buyer`
    ///      must match `msg.sender`. The recovered signer must be the listing seller or a signer
    ///      authorized by the seller for any listing that seller owns. The signed quote may also
    ///      include an optional integrator fee paid from the gross amount.
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

    /// @notice Return the canonical on-chain `purchaseRef` hash for an off-chain `rawPurchaseRef`.
    /// @dev `rawPurchaseRef` should be a short seller-side order reference such as
    ///      `ord_tg_20260502_f8K2pQ9z`. The hash is scoped by the
    ///      `zkReveal.purchaseRef.receipt.v1` domain, `block.chainid`, the settlement token,
    ///      `seller`, and `rawPurchaseRef`, so `rawPurchaseRef` does not need to include seller,
    ///      chain, token, or domain data itself. `listingId` is used only to validate that the
    ///      listing exists and belongs to `seller`; it is not included in the final hash. The
    ///      resulting `purchaseRef` is independent of receipt store address and listing ID, is
    ///      consumed through `PurchaseRefRegistry`, and prevents accidental replay across listings
    ///      and future settlement contracts that share the registry. Only the resulting
    ///      `bytes32 purchaseRef` is submitted or stored on-chain. `rawPurchaseRef` must be
    ///      non-empty and at most 128 bytes.
    function hashPurchaseRef(address seller, uint256 listingId, string calldata rawPurchaseRef)
        external
        view
        listingExists(listingId)
        returns (bytes32)
    {
        if (seller == address(0)) revert InvalidParams();
        if (listings[listingId].seller != seller) revert InvalidParams();
        _validateRawPurchaseRef(rawPurchaseRef);

        return keccak256(
            abi.encode(PURCHASE_REF_HASH_DOMAIN, block.chainid, address(settlementToken), seller, rawPurchaseRef)
        );
    }

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
    /// @dev The digest includes the derived seller, settlement token, immutable
    ///      `purchaseRefRegistry`, current chain ID, and this contract address. It may be signed
    ///      by the listing seller or by a seller-wide quote signer authorized by that seller.
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
    ///      listing active status, or purchaseRef replay status. Use
    ///      `validateSignedReceiptPurchase` when callers need the same validation path as
    ///      `purchaseSignedReceipt` without token transfer or receipt creation. `listingHash` is
    ///      an opaque seller-defined metadata commitment; human-readable product data remains
    ///      off-chain.
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
        _validatePurchaseRef(quote.purchaseRef);
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

    /// @notice Validate a seller-authorized signed quote without transferring funds or creating a receipt.
    /// @dev This applies the same validation path as `purchaseSignedReceipt`, including listing
    ///      activity, buyer binding, expiry bounds, replay protection, and seller-or-seller-wide
    ///      authorized signer verification. It is useful for frontends, bots, and backends that
    ///      want the final fee breakdown and recovered signer before prompting a buyer to approve
    ///      or pay.
    function validateSignedReceiptPurchase(
        SignedReceiptQuote calldata quote,
        bytes calldata sellerSignature,
        address expectedBuyer
    )
        external
        view
        listingExists(quote.listingId)
        returns (uint256, uint256, uint256, uint256, address, address, address, bytes32, address)
    {
        SignedReceiptPurchaseValidation memory validation =
            _validateSignedReceiptPurchaseView(quote, sellerSignature, expectedBuyer);

        return (
            validation.grossAmount,
            validation.protocolFee,
            validation.integratorFee,
            validation.sellerNet,
            validation.protocolFeeRecipient,
            validation.integratorFeeRecipient,
            validation.seller,
            validation.listingHash,
            validation.recoveredSigner
        );
    }

    function getListing(uint256 listingId) external view listingExists(listingId) returns (Listing memory) {
        return listings[listingId];
    }

    function getReceipt(uint256 receiptId) external view receiptExists(receiptId) returns (Receipt memory) {
        return receipts[receiptId];
    }

    /// @notice Return the locally recorded receipt ID for a seller-scoped lookup key, or 0 if absent.
    /// @dev Sellers, bots, and indexers can recompute the canonical hash from a revealed
    ///      `rawPurchaseRef` via `hashPurchaseRef` and use this getter as a deterministic on-chain
    ///      reconciliation helper for the matching receipt recorded by this store.
    function getReceiptIdBySellerAndPurchaseRef(address seller, bytes32 purchaseRef) external view returns (uint256) {
        return receiptIdBySellerAndPurchaseRef[seller][purchaseRef];
    }
}
