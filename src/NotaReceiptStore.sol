// SPDX-License-Identifier: Apache-2.0
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

/// @title NotaReceiptStore
/// @notice Seller-first managed receipt contract for Nota Receipt Mode.
/// @dev Sellers create listings with opaque metadata commitments and an immutable receipt issuance
///      mode. `PublicFixedPrice` listings can be purchased directly at a public unit price, while
///      `SignedQuoteOnly` listings require a seller-authorized EIP-712 quote. In both modes,
///      settlement completes immediately and emits `ReceiptPurchasedV2`, which is the receipt: no
///      per-receipt storage is written. Replay protection is enforced canonically through a shared
///      `PurchaseRefRegistry`. Listing and receipt discovery is expected to be handled from events
///      by indexers or seller systems; `purchaseRef` is an indexed topic so reconciliation works
///      from a plain `eth_getLogs` filter as well.
contract NotaReceiptStore is EIP712, ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    string public constant EIP712_NAME = "NotaReceiptStore";
    /// @dev Bumped to "2" for the storage-free receipt build. The domain separator already
    ///      differs per chain via `chainId` and `verifyingContract`, so this is a labelling
    ///      change rather than a replay barrier: it stops a v1 signing config from being pointed
    ///      at a v2 deployment and silently producing a digest the contract will reject.
    string public constant EIP712_VERSION = "2";
    /// @dev 50 bps = 0.5%.
    uint16 public constant MAX_PROTOCOL_FEE_BPS = 50;
    /// @dev 450 bps = 4.5%. Combined with the protocol fee cap, v1 fees cannot exceed 5%.
    uint16 public constant MAX_INTEGRATOR_FEE_BPS = 450;
    /// @dev v1 assumes a 6-decimal settlement token such as USDC.
    ///      `1e2` means 0.0001 USDC when the settlement token uses 6 decimals. The floor is set
    ///      this low deliberately: x402 agent payments are typically fractions of a cent, and a
    ///      1 USDC floor excluded them entirely.
    ///
    ///      Fee math holds at the floor. Both fees floor-divide, and the caps sum to 500 bps, so
    ///      `protocolFee + integratorFee <= grossAmount / 20` for every amount -- fees can never
    ///      reach the gross, and `sellerNet` is always at least 95% of it. At the floor itself a
    ///      50 bps protocol fee rounds to zero (it needs `grossAmount >= 200` to reach 1 base
    ///      unit) and the integrator fee caps at 4, so the seller nets at least 96 of 100.
    ///      Rounding therefore favours the seller, never the other way, and a zero `sellerNet`
    ///      is unreachable rather than merely unlikely.
    ///
    ///      This contract enforces only a minimum purchase amount.
    uint256 public constant MIN_PURCHASE_AMOUNT = 1e2;
    uint64 public constant MAX_QUOTE_TTL = 24 hours;
    uint256 public constant MAX_LISTINGS_PER_SELLER = 500;
    uint256 public constant MAX_QUOTE_SIGNERS_PER_LISTING = 3;
    string internal constant PURCHASE_REF_HASH_DOMAIN = "nota.purchaseRef.receipt.v1";
    uint256 internal constant MAX_RAW_PURCHASE_REF_LENGTH = 128;
    bytes32 public constant SIGNED_RECEIPT_QUOTE_TYPEHASH = keccak256(
        "SignedReceiptQuote(uint256 listingId,address seller,address buyer,bytes32 purchaseRef,uint256 amount,bytes32 metadataHash,address settlementToken,address purchaseRefRegistry,address integratorFeeRecipient,uint256 integratorFeeAmount,uint64 issuedAt,uint64 expiresAt)"
    );

    // -------------------------------------------------------------------------
    // Immutables
    // -------------------------------------------------------------------------

    /// @notice Settlement token used for all v1 purchases.
    /// @dev Official v1 deployments are intended for 6-decimal tokens such as USDC.
    ///      The constructor does not inspect token decimals.
    IERC20 public immutable SETTLEMENT_TOKEN;
    /// @notice Canonical protocol-level replay protection registry shared across settlement stores.
    PurchaseRefRegistry public immutable PURCHASE_REF_REGISTRY;
    address public immutable FEE_RECIPIENT;
    uint16 public immutable PROTOCOL_FEE_BPS;

    // -------------------------------------------------------------------------
    // Enums
    // -------------------------------------------------------------------------

    /// @notice Receipt issuance mode a listing is locked into at creation. Immutable in v1.
    /// @dev `PublicFixedPrice` means public direct checkout at the listing `unitPrice`: anyone may
    ///      buy directly via `purchaseReceipt`. Seller-authorized EIP-712 quotes via
    ///      `purchaseSignedReceipt` are ALSO allowed for these listings, which is what enables
    ///      buyer-bound payment links, metadata-bound checkout, integrator fees, discounts, and
    ///      bot, merchant-backend, or AI-agent checkout flows on top of a public listing.
    ///      `SignedQuoteOnly` means the listing must be purchased through a seller-authorized signed
    ///      quote: it carries no on-chain price (`unitPrice` is `0`), each quote carries its own
    ///      amount, and direct `purchaseReceipt` reverts with `ListingRequiresSignedQuote`. The
    ///      protocol only enforces whether a signed quote is required; who issues that quote
    ///      (seller wallet, backend, bot, dashboard) is an application-layer concern.
    enum ListingMode {
        PublicFixedPrice,
        SignedQuoteOnly
    }

    // -------------------------------------------------------------------------
    // Structs
    // -------------------------------------------------------------------------

    struct Listing {
        address seller;
        bytes32 listingHash;
        uint256 unitPrice;
        bool active;
        ListingMode mode;
    }

    /// @notice Seller-authorized EIP-712 quote for a receipt purchase, with optional buyer binding.
    /// @dev The signed digest binds the listing seller, `listingId`, `buyer`, `purchaseRef`,
    ///      `amount`, `metadataHash`, the v1 `SETTLEMENT_TOKEN`, the immutable
    ///      `PURCHASE_REF_REGISTRY`, optional integrator fee fields, seller-declared `issuedAt`,
    ///      `expiresAt`, `block.chainid`, and `address(this)`. `buyer` is optional: when it is a
    ///      non-zero address it must match `msg.sender` during `purchaseSignedReceipt`, so another
    ///      wallet cannot redeem the same quote; when it is the zero address the quote is unbound
    ///      and any wallet may submit and pay, with the payer recorded as the receipt buyer.
    ///      Single-use `purchaseRef` still prevents the quote from being redeemed more than once. The
    ///      quote may be signed by the seller directly or by a signer authorized for this listing with
    ///      `setListingQuoteSigner`. Authorization is listing-scoped in v1, so an authorized quote signer
    ///      can sign quotes only for the specific `listingId` where that signer was authorized.
    ///      A listing-authorized signer controls the full signed quote intent for that listing,
    ///      including amount, metadata, buyer binding, purchaseRef, and optional integrator fee fields.
    ///      `purchaseRef` is the seller-scoped `bytes32` hash of the off-chain
    ///      `(rawPurchaseRef, purchaseRefNonce)` entitlement bundle.
    ///      Only this hash belongs in the quote; `purchaseRefNonce` must remain off-chain and must
    ///      not be added to `SignedReceiptQuote` or settlement calldata. `metadataHash` commits to
    ///      the seller-authorized canonical checkout metadata (the v1 payment-intent payload) as
    ///      `keccak256` over its JCS-canonicalized JSON; it MUST be non-zero here and MUST NOT
    ///      commit to secrets or buyer PII (never `purchaseRefNonce`, unlock/delivery secrets,
    ///      private invite links, emails, phone numbers, or Telegram handles). The contract only
    ///      ever sees and stores this `bytes32` commitment; the readable metadata stays off-chain.
    ///      See "Canonical Checkout Metadata" in the contracts README for the v1 shape and rules.
    ///      `amount` is denominated in settlement token base units.
    ///      Integrator fee fields are optional, must be explicitly included in the
    ///      seller-authorized quote, and are paid from the gross `amount`; the seller receives
    ///      `amount - protocolFee - integratorFeeAmount`. `issuedAt` is the seller-declared quote
    ///      issuance timestamp, `expiresAt` must be greater than `issuedAt`, and
    ///      `expiresAt - issuedAt` must not exceed `MAX_QUOTE_TTL`.
    struct SignedReceiptQuote {
        uint256 listingId;
        address buyer;
        bytes32 purchaseRef;
        uint256 amount;
        /// @dev keccak256 over the JCS-canonicalized canonical checkout metadata. Non-zero, no secrets/PII.
        bytes32 metadataHash;
        address integratorFeeRecipient;
        uint256 integratorFeeAmount;
        uint64 issuedAt;
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
    /// @dev Monotonic receipt identifier. Receipts themselves are not stored on-chain: the
    ///      `ReceiptPurchasedV2` event is the record, and `purchaseRef` replay protection lives in
    ///      `PURCHASE_REF_REGISTRY`. This counter only keeps event ids unique and ordered.
    uint256 public nextReceiptId = 1;

    mapping(uint256 => Listing) public listings;
    /// @dev Enforces `MAX_LISTINGS_PER_SELLER`. Listing discovery is expected to come from
    ///      `ListingCreated` events or indexers, not on-chain enumeration.
    mapping(address seller => uint256 count) public listingCountBySeller;
    /// @dev Listing-scoped quote signer authorization.
    ///      `authorizedQuoteSigners[listingId][signer] = true` means `signer` may sign
    ///      `SignedReceiptQuote` values for that listing only.
    mapping(uint256 listingId => mapping(address signer => bool)) public authorizedQuoteSigners;
    /// @dev Number of currently authorized quote signers for each listing.
    mapping(uint256 listingId => uint256 count) public authorizedQuoteSignerCount;

    bool public listingCreationPaused;
    bool public purchasesPaused;
    bool public quoteSignerUpdatesPaused;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event ListingCreated(
        uint256 indexed listingId,
        address indexed seller,
        bytes32 indexed listingHash,
        uint256 unitPrice,
        ListingMode mode
    );

    event ListingStatusChanged(uint256 indexed listingId, address indexed seller, bool active);

    /// @dev `purchaseRef` is indexed so a plain `eth_getLogs` filter can resolve a purchase
    ///      reference to its settlement without an indexer. That lookup is the reconciliation
    ///      path, and it is why `purchaseRef` takes one of the three topic slots ahead of
    ///      `receiptId`: nobody searches for a receipt id they do not already have.
    ///
    ///      The `V2` suffix is load-bearing. Indexedness is not part of an event signature, so
    ///      keeping the v1 name would have produced an identical `topic0` with a different topic
    ///      layout to the live v1 deployment -- an indexer matching on `topic0` alone would decode
    ///      a seller address as a receipt id and never raise an error. A distinct name makes the
    ///      two impossible to confuse without anyone having to read documentation.
    event ReceiptPurchasedV2(
        uint256 receiptId,
        address indexed seller,
        address indexed buyer,
        uint256 listingId,
        bytes32 indexed purchaseRef,
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

    event QuoteSignerAuthorizationChanged(
        uint256 indexed listingId, address indexed seller, address indexed signer, bool authorized
    );
    event ListingCreationPauseChanged(bool paused);
    event PurchasesPauseChanged(bool paused);
    event QuoteSignerUpdatesPauseChanged(bool paused);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error ListingNotFound();
    error NotListingSeller();
    error ListingInactive();
    error ListingRequiresSignedQuote();
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
    error PriceMismatch();

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier listingExists(uint256 listingId) {
        _listingExists(listingId);
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

        SETTLEMENT_TOKEN = IERC20(settlementToken_);
        PURCHASE_REF_REGISTRY = PurchaseRefRegistry(purchaseRefRegistry_);
        FEE_RECIPIENT = feeRecipient_;
        PROTOCOL_FEE_BPS = protocolFeeBps_;
    }

    // -------------------------------------------------------------------------
    // Internal Helpers
    // -------------------------------------------------------------------------

    function _validateOwner(address owner_) internal pure returns (address validatedOwner) {
        if (owner_ == address(0)) revert InvalidParams();
        return owner_;
    }

    function _validatePurchaseAmount(uint256 amount) internal pure {
        if (amount < MIN_PURCHASE_AMOUNT) {
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
        return grossAmount * PROTOCOL_FEE_BPS / FeeMath.BPS_DENOMINATOR;
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
            protocolFeeRecipient: FEE_RECIPIENT,
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
            SETTLEMENT_TOKEN.safeTransfer(rake.protocolFeeRecipient, rake.protocolFee);
            emit ProtocolFeePaid(receiptId, listingId, rake.protocolFeeRecipient, rake.protocolFee);
        }

        if (rake.integratorFee > 0) {
            SETTLEMENT_TOKEN.safeTransfer(rake.integratorFeeRecipient, rake.integratorFee);
            emit IntegratorFeePaid(receiptId, listingId, rake.integratorFeeRecipient, rake.integratorFee);
        }

        SETTLEMENT_TOKEN.safeTransfer(seller, rake.sellerNet);
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
                    address(SETTLEMENT_TOKEN),
                    address(PURCHASE_REF_REGISTRY),
                    quote.integratorFeeRecipient,
                    quote.integratorFeeAmount,
                    quote.issuedAt,
                    quote.expiresAt
                )
            )
        );
    }

    function _listingExists(uint256 listingId) internal view {
        if (listings[listingId].seller == address(0)) revert ListingNotFound();
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
        // A zero `buyer` leaves the quote unbound (any wallet may submit and pay); a non-zero
        // `buyer` is enforced against the caller so a leaked quote cannot be redeemed by others.
        if (quote.buyer != address(0) && quote.buyer != expectedBuyer) revert QuoteBuyerMismatch();
        _validatePurchaseRef(quote.purchaseRef);
        if (quote.metadataHash == bytes32(0)) revert InvalidParams();
        _validatePurchaseAmount(quote.amount);
        _validateIntegratorFee(quote.integratorFeeRecipient, quote.integratorFeeAmount, quote.amount);
        if (quote.issuedAt > block.timestamp) revert InvalidParams();
        if (quote.expiresAt <= quote.issuedAt) revert InvalidParams();
        if (quote.expiresAt <= block.timestamp) revert QuoteExpired();
        if (quote.expiresAt - quote.issuedAt > MAX_QUOTE_TTL) revert QuoteExpiryTooLong();
        if (PURCHASE_REF_REGISTRY.isConsumed(quote.purchaseRef)) {
            revert PurchaseRefAlreadyUsed();
        }

        bytes32 digest = _hashSignedReceiptQuote(quote, listing.seller);
        signer = ECDSA.recover(digest, sellerSignature);
        if (signer != listing.seller && !authorizedQuoteSigners[quote.listingId][signer]) {
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

        SETTLEMENT_TOKEN.safeTransferFrom(payer, address(this), amount);
        PURCHASE_REF_REGISTRY.consume(purchaseRef);

        receiptId = nextReceiptId++;

        _distributeReceiptPurchaseProceeds(receiptId, listingId, seller, rake);

        emit ReceiptPurchasedV2(receiptId, seller, receiptBuyer, listingId, purchaseRef, amount, metadataHash);
    }

    // -------------------------------------------------------------------------
    // Seller Configuration Functions
    // -------------------------------------------------------------------------

    /// @notice Authorize or revoke a signer for one seller-owned listing's signed receipt quotes.
    /// @dev When authorized, `signer` can sign `SignedReceiptQuote` values only for `listingId`.
    ///      The signer can set the full signed quote intent for that listing, including optional
    ///      integrator fee fields, within the protocol's fee caps.
    ///      Treat authorized signers as hot operational keys and revoke compromised signers
    ///      immediately with `setListingQuoteSigner(listingId, signer, false)`.
    function setListingQuoteSigner(uint256 listingId, address signer, bool authorized)
        external
        listingExists(listingId)
    {
        if (quoteSignerUpdatesPaused) revert QuoteSignerUpdatesPaused();
        _onlyListingSeller(listingId);
        if (signer == address(0)) revert InvalidParams();
        if (signer == msg.sender) revert InvalidParams();
        bool currentlyAuthorized = authorizedQuoteSigners[listingId][signer];
        if (authorized == currentlyAuthorized) {
            emit QuoteSignerAuthorizationChanged(listingId, msg.sender, signer, authorized);
            return;
        }

        if (authorized) {
            if (authorizedQuoteSignerCount[listingId] >= MAX_QUOTE_SIGNERS_PER_LISTING) {
                revert QuoteSignerLimitReached();
            }
            authorizedQuoteSignerCount[listingId]++;
        } else {
            authorizedQuoteSignerCount[listingId]--;
        }

        authorizedQuoteSigners[listingId][signer] = authorized;

        emit QuoteSignerAuthorizationChanged(listingId, msg.sender, signer, authorized);
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

    /// @notice Create a seller-owned listing for Receipt Mode purchases in an explicit purchase mode.
    /// @dev `listingHash` is an opaque seller-defined metadata commitment. Human-readable product
    ///      data lives off-chain, for example inside a seller-signed payment link. `mode` selects
    ///      how the listing may be purchased and is immutable for the lifetime of the listing; v1
    ///      intentionally has no `setListingMode`. To move a product to a different mode, deactivate
    ///      the listing with `setListingActive(listingId, false)` and create a new one.
    ///
    ///      For `ListingMode.PublicFixedPrice`, `unitPrice` is the immutable on-chain price
    ///      (denominated in settlement token base units), must pass `_validatePurchaseAmount`, and
    ///      can be bought directly via `purchaseReceipt` or through a seller-authorized signed quote
    ///      via `purchaseSignedReceipt`. To change a fixed price, create a new listing.
    ///
    ///      For `ListingMode.SignedQuoteOnly`, `unitPrice` must be exactly `0`: the listing carries
    ///      no on-chain price and is purchasable only through a seller-authorized signed quote,
    ///      whose `amount` is validated at purchase time. Direct `purchaseReceipt` reverts with
    ///      `ListingRequiresSignedQuote`.
    function createListing(bytes32 listingHash, uint256 unitPrice, ListingMode mode)
        external
        returns (uint256 listingId)
    {
        if (listingCreationPaused) revert ListingCreationPaused();
        if (listingHash == bytes32(0)) revert InvalidParams();
        if (mode == ListingMode.PublicFixedPrice) {
            _validatePurchaseAmount(unitPrice);
        } else if (unitPrice != 0) {
            // SignedQuoteOnly listings carry no on-chain price; per-order pricing lives in each
            // seller-authorized signed quote, so a non-zero unitPrice is rejected as invalid.
            revert InvalidParams();
        }
        if (listingCountBySeller[msg.sender] >= MAX_LISTINGS_PER_SELLER) {
            revert SellerListingLimitReached();
        }

        listingId = nextListingId++;

        Listing storage listing = listings[listingId];
        listing.seller = msg.sender;
        listing.listingHash = listingHash;
        listing.unitPrice = unitPrice;
        listing.active = true;
        listing.mode = mode;

        listingCountBySeller[msg.sender]++;

        emit ListingCreated(listingId, msg.sender, listingHash, unitPrice, mode);
    }

    /// @notice Update the active status of a seller-owned listing.
    /// @dev Listing prices are immutable after `createListing`. To change the price for a product,
    ///      the seller must create a new listing and optionally deactivate the old one.
    function setListingActive(uint256 listingId, bool active) external listingExists(listingId) {
        _onlyListingSeller(listingId);
        listings[listingId].active = active;
        emit ListingStatusChanged(listingId, msg.sender, active);
    }

    // -------------------------------------------------------------------------
    // Purchase Functions
    // -------------------------------------------------------------------------

    /// @notice Purchase a public fixed-price Receipt Mode listing using a seller-scoped `purchaseRef` hash.
    /// @dev This is the simple public purchase path and is valid only for
    ///      `ListingMode.PublicFixedPrice` listings; a `ListingMode.SignedQuoteOnly` listing reverts
    ///      with `ListingRequiresSignedQuote` and must be bought through `purchaseSignedReceipt`.
    ///      The buyer must pass the exact listing
    ///      `unitPrice` as `amount`; the contract reverts with `PriceMismatch` if it differs in
    ///      either direction. Together with immutable listing prices (no `setListingPrice` exists
    ///      in v1), this means the on-chain price the buyer asserts is the price they pay. The
    ///      caller is not buyer-bound before submission, and `msg.sender` is recorded as the
    ///      buyer. Any wallet that submits a valid unconsumed `purchaseRef` first and pays first
    ///      receives the receipt. `purchaseRef` should normally be the output of
    ///      `hashPurchaseRef(seller, listingId, rawPurchaseRef, purchaseRefNonce)`, where
    ///      `(rawPurchaseRef, purchaseRefNonce)` remains an off-chain entitlement bundle held by
    ///      seller infrastructure. Only the resulting `bytes32 purchaseRef` is submitted here.
    ///      Cross-listing reuse is prevented by `PurchaseRefRegistry.consume(purchaseRef)`, not by
    ///      including `listingId` in the hash.`listingId` is accepted by `hashPurchaseRef` only to validate seller ownership;
    ///       it is not part of the purchaseRef preimage.  Use `purchaseSignedReceipt` instead for buyer-bound payment links,
    ///      private checkout flows, dynamic pricing, or integrator fees. This direct path commits no
    ///      off-chain checkout metadata, so `ReceiptPurchasedV2` is emitted with
    ///      `metadataHash = bytes32(0)`. Payment settles
    ///      immediately and fulfillment remains entirely off-chain in seller systems. Receipt
    ///      discovery is expected to be handled from `ReceiptPurchasedV2` events or indexers.
    function purchaseReceipt(uint256 listingId, bytes32 purchaseRef, uint256 amount)
        external
        nonReentrant
        listingExists(listingId)
        returns (uint256 receiptId)
    {
        if (purchasesPaused) revert PurchasesPaused();
        Listing storage listing = listings[listingId];

        if (!listing.active) revert ListingInactive();
        if (listing.mode != ListingMode.PublicFixedPrice) revert ListingRequiresSignedQuote();
        _validatePurchaseRef(purchaseRef);
        if (listing.unitPrice != amount) revert PriceMismatch();
        if (PURCHASE_REF_REGISTRY.isConsumed(purchaseRef)) {
            revert PurchaseRefAlreadyUsed();
        }

        return _settleReceiptPurchase(
            listingId, listing.seller, msg.sender, msg.sender, amount, purchaseRef, bytes32(0), address(0), 0
        );
    }

    /// @notice Purchase a Receipt Mode listing using a seller-authorized EIP-712 quote.
    /// @dev Valid for both listing modes: it is the required path for `ListingMode.SignedQuoteOnly`
    ///      listings and an additional supported path for `ListingMode.PublicFixedPrice` listings
    ///      (buyer-bound payment links, metadata-bound checkout, dynamic pricing, integrator fees).
    ///      This is the recommended v1 flow for production checkout and payment-link integrations.
    ///      Seller Payment Link Mode uses a quote signed by the listing seller or a signer authorized
    ///      for the quoted listing, with `quote.purchaseRef` carrying the seller-scoped hash
    ///      derived from an off-chain `(rawPurchaseRef, purchaseRefNonce)` entitlement bundle. The
    ///      nonce stays off-chain and must not be added to `SignedReceiptQuote` or settlement
    ///      calldata; only the resulting `bytes32 purchaseRef` is submitted. The signed quote binds the buyer, seller,
    ///      listing, `purchaseRef`, amount, metadata, settlement token, `PURCHASE_REF_REGISTRY`,
    ///      expiry, chain, and contract. For public fixed-price listings, the signed amount
    ///      overrides the listing unit price and settles immediately on success; for quote-only
    ///      listings, the signed amount is the seller-authorized price. The shared
    ///      `PurchaseRefRegistry` is the canonical replay protection layer across settlement
    ///      contracts. `quote.issuedAt` is the seller-declared quote issuance timestamp and part
    ///      of the signed EIP-712 payload. A signed quote is valid only between `issuedAt` and
    ///      `expiresAt`, and `quote.expiresAt - quote.issuedAt` must not exceed
    ///      `MAX_QUOTE_TTL`. If `quote.buyer` is non-zero it must match `msg.sender`; a zero
    ///      `quote.buyer` leaves the quote unbound so any wallet may purchase it. The recovered signer must be
    ///      the listing seller or a signer authorized specifically for `quote.listingId`. The signed quote may
    ///      also include an optional integrator fee paid from the
    ///      gross amount. `quote.metadataHash` must be non-zero and commits to the seller-authorized
    ///      canonical checkout metadata (keccak256 over its JCS-canonicalized JSON); the contract
    ///      only sees/stores that `bytes32` and emits it in `ReceiptPurchasedV2`.
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

    /// @notice Return the canonical on-chain `purchaseRef` hash for an off-chain
    ///         `(rawPurchaseRef, purchaseRefNonce)` bundle.
    /// @dev `rawPurchaseRef` is the human/business identifier (e.g. `invoice-123` or the canonical
    ///      `<namespace>_<context>_<random>` form like `rev_topup_4f8c1d9a2b7e6035a1c4d8e9f0b2a6c3`),
    ///      while `purchaseRefNonce` is a secret high-entropy random `bytes32` salt. The cryptographic
    ///      strength of the commitment comes from `purchaseRefNonce`: even a guessable
    ///      `rawPurchaseRef` cannot be brute-forced into the on-chain `purchaseRef` without knowing
    ///      the nonce. `(rawPurchaseRef, purchaseRefNonce)` is the off-chain entitlement bundle and
    ///      may be held by a seller backend, merchant link, bot, integrator, or buyer-facing app;
    ///      the buyer does not necessarily see the nonce directly. `purchaseRefNonce` must remain
    ///      off-chain and must not be added to `SignedReceiptQuote` or settlement calldata. Only
    ///      the resulting `bytes32 purchaseRef` hash is submitted on-chain.
    ///      The hash is seller-scoped by the Nota domain string
    ///      `nota.purchaseRef.receipt.v1`, `block.chainid`, the settlement token, `seller`,
    ///      `rawPurchaseRef`, and `purchaseRefNonce`, so `rawPurchaseRef` does not need to include
    ///      seller, chain, token, or domain data itself. `listingId` is validated only to confirm
    ///      that `seller` owns the listing; it is intentionally not included in the hash. Reuse
    ///      across listings is prevented by single-use consumption in `PurchaseRefRegistry`, not by
    ///      `listingId` being part of the hash. `rawPurchaseRef` must be non-empty and at most
    ///      128 bytes; `purchaseRefNonce` is accepted as-is (a non-zero, CSPRNG-generated value is
    ///      required for the security property but is not enforced here, since callers may compute
    ///      this hash off-chain).
    function hashPurchaseRef(
        address seller,
        uint256 listingId,
        string calldata rawPurchaseRef,
        bytes32 purchaseRefNonce
    ) external view listingExists(listingId) returns (bytes32) {
        if (seller == address(0)) revert InvalidParams();
        if (listings[listingId].seller != seller) revert InvalidParams();
        _validateRawPurchaseRef(rawPurchaseRef);

        // The abi.encode layout here is the locked purchaseRef preimage; this is a view helper, so
        // keep the standard keccak (no inline asm) and silence the gas-only lint.
        // forge-lint: disable-start(asm-keccak256)
        return keccak256(
            abi.encode(
                PURCHASE_REF_HASH_DOMAIN,
                block.chainid,
                address(SETTLEMENT_TOKEN),
                seller,
                rawPurchaseRef,
                purchaseRefNonce
            )
        );
        // forge-lint: disable-end(asm-keccak256)
    }

    /// @notice Quote gross amount, protocol fee, seller net, and fee recipient for a public
    /// fixed-price receipt purchase.
    /// @dev Valid only for `ListingMode.PublicFixedPrice` listings, which carry an on-chain
    ///      `unitPrice`. A `ListingMode.SignedQuoteOnly` listing has no on-chain price (`unitPrice`
    ///      is intentionally `0`), so this reverts with `ListingRequiresSignedQuote`; price such
    ///      listings from their seller-authorized signed quote via `previewSignedReceiptPurchase`
    ///      instead.
    function quotePurchaseReceipt(uint256 listingId)
        external
        view
        listingExists(listingId)
        returns (uint256 grossAmount, uint256 protocolFee, uint256 sellerNet, address quotedFeeRecipient)
    {
        Listing storage listing = listings[listingId];
        if (listing.mode != ListingMode.PublicFixedPrice) revert ListingRequiresSignedQuote();
        RakeQuote memory rake = _quoteRake(listing.unitPrice, address(0), 0);
        grossAmount = rake.grossAmount;
        protocolFee = rake.protocolFee;
        sellerNet = rake.sellerNet;
        quotedFeeRecipient = rake.protocolFeeRecipient;
    }

    /// @notice Returns the EIP-712 digest for a seller-authorized signed receipt quote.
    /// @dev The digest includes the derived seller, settlement token, immutable
    ///      `PURCHASE_REF_REGISTRY`, current chain ID, and this contract address. It may be signed
    ///      by the listing seller or by a quote signer authorized for the quoted listing.
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
    ///      listing active status, or purchaseRef replay status. For `SignedQuoteOnly` listings, this
    ///      is the preview path for quote-carried pricing. Use `validateSignedReceiptPurchase` when
    ///      callers need the same validation path as `purchaseSignedReceipt` without token transfer or
    ///      receipt creation. `listingHash` is an opaque seller-defined metadata commitment;
    ///      human-readable product data remains off-chain.
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
    ///      activity, optional buyer binding (enforced only when `quote.buyer` is non-zero),
    ///      `issuedAt`/`expiresAt` lifetime bounds, replay protection,
    ///      and seller-or-listing-authorized signer verification. `quote.issuedAt` is the
    ///      seller-declared quote issuance timestamp and part of the signed EIP-712 payload. A
    ///      signed quote is valid only between `issuedAt` and `expiresAt`, and
    ///      `quote.expiresAt - quote.issuedAt` must not exceed `MAX_QUOTE_TTL`. It is useful for
    ///      frontends, bots, and backends that want the final fee breakdown and recovered signer
    ///      before prompting a buyer to approve or pay.
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

    /// @notice Return whether `signer` can sign valid receipt quotes for `listingId`.
    /// @dev The listing seller is always a valid direct signer without delegated authorization.
    function isQuoteSignerAuthorized(uint256 listingId, address signer)
        external
        view
        listingExists(listingId)
        returns (bool)
    {
        Listing storage listing = listings[listingId];
        return signer == listing.seller || authorizedQuoteSigners[listingId][signer];
    }
}
