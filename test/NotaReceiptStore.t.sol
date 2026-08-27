// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {PurchaseRefRegistry} from "../src/PurchaseRefRegistry.sol";
import {NotaReceiptStore} from "../src/NotaReceiptStore.sol";

/// @dev Minimal ERC-1271 contract wallet, standing in for Coinbase Smart Wallet. Signature
///      validity depends on the *current* owner, so rotating the owner invalidates signatures the
///      wallet previously produced -- the behaviour `SignatureChecker.isValidSignatureNow` is
///      named for.
contract MockSmartWallet {
    bytes4 internal constant ERC1271_MAGIC_VALUE = 0x1626ba7e;

    address public owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function rotateOwner(address newOwner) external {
        owner = newOwner;
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, signature);
        if (err == ECDSA.RecoverError.NoError && recovered == owner) {
            return ERC1271_MAGIC_VALUE;
        }
        return 0xffffffff;
    }
}

/// @dev An ERC-1271 wallet that rejects everything, standing in for a hostile or broken wallet.
contract RejectingSmartWallet {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0xffffffff;
    }
}

contract ReceiptMockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract NotaReceiptStoreHarness is NotaReceiptStore {
    constructor(
        address settlementToken_,
        address purchaseRefRegistry_,
        address feeRecipient_,
        uint16 protocolFeeBps_,
        address owner_
    ) NotaReceiptStore(settlementToken_, purchaseRefRegistry_, feeRecipient_, protocolFeeBps_, owner_) {}

    function purchaseSignedReceiptForPayerAndExpectedBuyer(
        SignedReceiptQuote calldata quote,
        bytes calldata sellerSignature,
        address payer,
        address expectedBuyer
    ) external nonReentrant listingExists(quote.listingId) returns (uint256 receiptId) {
        if (purchasesPaused) revert PurchasesPaused();
        Listing storage listing = _verifySignedReceiptQuote(quote, sellerSignature, expectedBuyer, address(0));

        return _settleVerifiedSignedReceiptQuote(listing, quote, payer, expectedBuyer);
    }

    function _settleVerifiedSignedReceiptQuote(
        Listing storage listing,
        SignedReceiptQuote calldata quote,
        address payer,
        address expectedBuyer
    ) internal returns (uint256 receiptId) {
        return _settleReceiptPurchase(
            ReceiptSettlement({
                listingId: quote.listingId,
                seller: listing.seller,
                payer: payer,
                receiptBuyer: expectedBuyer,
                amount: quote.amount,
                purchaseRef: quote.purchaseRef,
                metadataHash: quote.metadataHash,
                agentId: quote.agentId,
                integratorFeeRecipient: quote.integratorFeeRecipient,
                integratorFeeAmount: quote.integratorFeeAmount
            })
        );
    }
}

contract NotaReceiptStoreTest is Test {
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    uint256 internal constant SELLER_PK = 0xA11CE;
    uint256 internal constant SELLER2_PK = 0xABCD;
    uint256 internal constant QUOTE_SIGNER_PK = 0xBEEF;
    uint256 internal constant ATTACKER_PK = 0xD00D;

    ReceiptMockUSDC usdc;
    PurchaseRefRegistry registry;
    NotaReceiptStore store;

    address seller;
    address seller2;
    address quoteSigner;
    address buyer = address(0xB0B);
    address buyer2 = address(0xCAFE);
    address attacker;
    address feeRecipient = address(0xFEE);
    address internal constant INTEGRATOR = address(0x1A7E);

    bytes32 listingHash = keccak256("listing-1");
    bytes32 listingHash2 = keccak256("listing-2");
    bytes32 metadataHash = keccak256("metadata-1");
    bytes32 metadataHash2 = keccak256("metadata-2");
    uint256 unitPrice = 100_000_000;
    uint256 quotedAmount = 250_000_000;
    uint256 largePurchaseAmount = 7_500_000_000; // 7,500 USDC
    bytes32 purchaseRef = keccak256("purchase-1");
    bytes32 purchaseRef2 = keccak256("purchase-2");
    bytes32 purchaseRefNonce = keccak256("nonce-1");
    bytes32 purchaseRefNonce2 = keccak256("nonce-2");

    function setUp() public {
        usdc = new ReceiptMockUSDC();
        registry = new PurchaseRefRegistry(address(this));
        seller = vm.addr(SELLER_PK);
        seller2 = vm.addr(SELLER2_PK);
        quoteSigner = vm.addr(QUOTE_SIGNER_PK);
        attacker = vm.addr(ATTACKER_PK);
        store = new NotaReceiptStore(address(usdc), address(registry), feeRecipient, 0, address(this));
        registry.setConsumerAuthorization(address(store), true);

        usdc.mint(buyer, 10_000_000_000);
        usdc.mint(buyer2, 10_000_000_000);
        usdc.mint(attacker, 10_000_000_000);

        vm.deal(seller, 10 ether);
        vm.deal(seller2, 10 ether);
        vm.deal(buyer, 10 ether);
        vm.deal(buyer2, 10 ether);
        vm.deal(attacker, 10 ether);

        // Receipts live in events now, so every test needs the log buffer running.
        vm.recordLogs();
    }

    function _authorizeRegistryConsumer(PurchaseRefRegistry targetRegistry, address consumer) internal {
        targetRegistry.setConsumerAuthorization(consumer, true);
    }

    function _deployStore(uint16 feeBps) internal returns (NotaReceiptStore deployedStore) {
        deployedStore = _deployStore(feeBps, address(this), registry);
    }

    function _deployStore(uint16 feeBps, address owner_) internal returns (NotaReceiptStore deployedStore) {
        deployedStore = _deployStore(feeBps, owner_, registry);
    }

    function _deployStore(uint16 feeBps, address owner_, PurchaseRefRegistry targetRegistry)
        internal
        returns (NotaReceiptStore deployedStore)
    {
        deployedStore = new NotaReceiptStore(address(usdc), address(targetRegistry), feeRecipient, feeBps, owner_);
        _authorizeRegistryConsumer(targetRegistry, address(deployedStore));
    }

    function _deployHarnessStore(uint16 feeBps) internal returns (NotaReceiptStoreHarness deployedStore) {
        deployedStore = _deployHarnessStore(feeBps, address(this), registry);
    }

    function _deployHarnessStore(uint16 feeBps, address owner_)
        internal
        returns (NotaReceiptStoreHarness deployedStore)
    {
        deployedStore = _deployHarnessStore(feeBps, owner_, registry);
    }

    function _deployHarnessStore(uint16 feeBps, address owner_, PurchaseRefRegistry targetRegistry)
        internal
        returns (NotaReceiptStoreHarness deployedStore)
    {
        deployedStore =
            new NotaReceiptStoreHarness(address(usdc), address(targetRegistry), feeRecipient, feeBps, owner_);
        _authorizeRegistryConsumer(targetRegistry, address(deployedStore));
    }

    function _createListingAs(address sellerAccount, bytes32 sellerListingHash) internal returns (uint256 listingId) {
        listingId = _createListingAs(store, sellerAccount, sellerListingHash, unitPrice);
    }

    function _createListingAs(address sellerAccount, bytes32 sellerListingHash, uint256 price)
        internal
        returns (uint256 listingId)
    {
        listingId = _createListingAs(store, sellerAccount, sellerListingHash, price);
    }

    function _createListingAs(
        NotaReceiptStore targetStore,
        address sellerAccount,
        bytes32 sellerListingHash,
        uint256 price
    ) internal returns (uint256 listingId) {
        listingId = _createListingAs(
            targetStore, sellerAccount, sellerListingHash, price, NotaReceiptStore.ListingMode.PublicFixedPrice
        );
    }

    function _createListingAs(
        NotaReceiptStore targetStore,
        address sellerAccount,
        bytes32 sellerListingHash,
        uint256 price,
        NotaReceiptStore.ListingMode mode
    ) internal returns (uint256 listingId) {
        vm.prank(sellerAccount);
        listingId = targetStore.createListing(sellerListingHash, price, mode);
    }

    function _createListingAs(NotaReceiptStore targetStore, address sellerAccount, bytes32 sellerListingHash)
        internal
        returns (uint256 listingId)
    {
        listingId = _createListingAs(targetStore, sellerAccount, sellerListingHash, unitPrice);
    }

    function _createListingAsSeller() internal returns (uint256 listingId) {
        listingId = _createListingAs(seller, listingHash);
    }

    function _createListingAsSeller(uint256 price) internal returns (uint256 listingId) {
        listingId = _createListingAs(seller, listingHash, price);
    }

    function _setListingQuoteSigner(
        NotaReceiptStore targetStore,
        address sellerAccount,
        uint256 listingId,
        address signer,
        bool authorized
    ) internal {
        vm.prank(sellerAccount);
        targetStore.setListingQuoteSigner(listingId, signer, authorized);
    }

    function _purchaseReceiptAs(NotaReceiptStore targetStore, uint256 listingId, address who, bytes32 ref)
        internal
        returns (uint256 receiptId)
    {
        NotaReceiptStore.Listing memory listing = targetStore.getListing(listingId);

        vm.startPrank(who);
        usdc.approve(address(targetStore), listing.unitPrice);
        receiptId = targetStore.purchaseReceipt(listingId, ref, listing.unitPrice);
        vm.stopPrank();
    }

    function _purchaseReceiptAs(uint256 listingId, address who, bytes32 ref) internal returns (uint256 receiptId) {
        receiptId = _purchaseReceiptAs(store, listingId, who, ref);
    }

    function _makeSignedReceiptQuote(
        uint256 listingId,
        address quoteBuyer,
        bytes32 ref,
        uint256 amount,
        uint64 expiresAt
    ) internal view returns (NotaReceiptStore.SignedReceiptQuote memory quote) {
        quote = _makeSignedReceiptQuoteWithIntegrator(listingId, quoteBuyer, ref, amount, address(0), 0, expiresAt);
    }

    function _makeSignedReceiptQuoteWithIntegrator(
        uint256 listingId,
        address quoteBuyer,
        bytes32 ref,
        uint256 amount,
        address integratorFeeRecipient,
        uint256 integratorFeeAmount,
        uint64 expiresAt
    ) internal view returns (NotaReceiptStore.SignedReceiptQuote memory quote) {
        quote = NotaReceiptStore.SignedReceiptQuote({
            listingId: listingId,
            buyer: quoteBuyer,
            purchaseRef: ref,
            amount: amount,
            metadataHash: metadataHash,
            agentId: bytes32(0),
            integratorFeeRecipient: integratorFeeRecipient,
            integratorFeeAmount: integratorFeeAmount,
            issuedAt: uint64(block.timestamp),
            expiresAt: expiresAt
        });
    }

    function _signSignedReceiptQuote(
        NotaReceiptStore targetStore,
        uint256 signerPk,
        NotaReceiptStore.SignedReceiptQuote memory quote
    ) internal view returns (bytes memory signature) {
        bytes32 digest = targetStore.hashSignedReceiptQuote(quote);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        signature = abi.encodePacked(r, s, v);
    }

    function _purchaseSignedReceiptAs(
        NotaReceiptStore targetStore,
        address who,
        NotaReceiptStore.SignedReceiptQuote memory quote,
        bytes memory sellerSignature
    ) internal returns (uint256 receiptId) {
        receiptId = _purchaseSignedReceiptAs(targetStore, who, quote, sellerSignature, address(0));
    }

    /// @dev `claimedSigner` names the address that produced the signature; `address(0)` means the
    ///      listing seller. A quote signed by a listing-authorized signer must name that signer,
    ///      because `SignatureChecker` verifies a supplied candidate rather than recovering one.
    function _purchaseSignedReceiptAs(
        NotaReceiptStore targetStore,
        address who,
        NotaReceiptStore.SignedReceiptQuote memory quote,
        bytes memory sellerSignature,
        address claimedSigner
    ) internal returns (uint256 receiptId) {
        vm.startPrank(who);
        usdc.approve(address(targetStore), quote.amount);
        receiptId = targetStore.purchaseSignedReceipt(quote, sellerSignature, claimedSigner);
        vm.stopPrank();
    }

    function _expectedSignedReceiptQuoteDigest(
        NotaReceiptStore targetStore,
        NotaReceiptStore.SignedReceiptQuote memory quote
    ) internal view returns (bytes32) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("NotaReceiptStore")),
                // Deliberately hardcoded rather than read from EIP712_VERSION: this rebuilds the
                // domain independently, so it is the canary that fires if the separator changes.
                keccak256(bytes("2")),
                block.chainid,
                address(targetStore)
            )
        );

        return keccak256(
            abi.encodePacked("\x19\x01", domainSeparator, _expectedSignedReceiptQuoteStructHash(targetStore, quote))
        );
    }

    function _expectedSignedReceiptQuoteStructHash(
        NotaReceiptStore targetStore,
        NotaReceiptStore.SignedReceiptQuote memory quote
    ) internal view returns (bytes32) {
        NotaReceiptStore.Listing memory listing = targetStore.getListing(quote.listingId);

        return keccak256(
            abi.encode(
                targetStore.SIGNED_RECEIPT_QUOTE_TYPEHASH(),
                quote.listingId,
                listing.seller,
                quote.buyer,
                quote.purchaseRef,
                quote.amount,
                quote.metadataHash,
                quote.agentId,
                address(targetStore.SETTLEMENT_TOKEN()),
                address(targetStore.PURCHASE_REF_REGISTRY()),
                quote.integratorFeeRecipient,
                quote.integratorFeeAmount,
                quote.issuedAt,
                quote.expiresAt
            )
        );
    }

    function _makeListingHash(uint256 nonce) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("listing-", nonce));
    }

    function _makePurchaseRef(uint256 nonce) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("purchase-", nonce));
    }

    function _makeRawPurchaseRef(uint256 nonce) internal pure returns (string memory) {
        return string(abi.encodePacked("ord_tg_20260502_", bytes1(uint8(48 + (nonce % 10)))));
    }

    function _makeStringOfLength(uint256 length) internal pure returns (string memory value) {
        bytes memory buffer = new bytes(length);
        for (uint256 i; i < length; ++i) {
            buffer[i] = bytes1(uint8(97 + (i % 26)));
        }
        value = string(buffer);
    }

    function _expectedPurchaseRefHash(address sellerAccount, string memory rawPurchaseRef, bytes32 nonce)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                "nota.purchaseRef.receipt.v1", block.chainid, address(usdc), sellerAccount, rawPurchaseRef, nonce
            )
        );
    }

    /// @dev Receipts are not stored on-chain: the `ReceiptPurchasedV2` event is the record, and
    ///      replay protection lives in `PURCHASE_REF_REGISTRY`. Tests that used to read the
    ///      receipt struct decode the event instead.
    struct EmittedReceipt {
        uint256 receiptId;
        address seller;
        address buyer;
        uint256 listingId;
        bytes32 purchaseRef;
        uint256 amount;
        bytes32 metadataHash;
        bytes32 agentId;
    }

    bytes32 internal constant RECEIPT_PURCHASED_TOPIC =
        keccak256("ReceiptPurchasedV2(uint256,address,address,uint256,bytes32,uint256,bytes32,bytes32)");

    /// @dev Most recent `ReceiptPurchasedV2` emitted since logs were last drained. `setUp` starts
    ///      recording, so any test can call this after a purchase.
    function _lastEmittedReceipt() internal view returns (EmittedReceipt memory receipt) {
        Vm.Log[] memory logs = vm.getRecordedLogs();

        for (uint256 i = logs.length; i > 0; i--) {
            Vm.Log memory entry = logs[i - 1];
            if (entry.topics.length != 4 || entry.topics[0] != RECEIPT_PURCHASED_TOPIC) continue;

            receipt.seller = address(uint160(uint256(entry.topics[1])));
            receipt.buyer = address(uint160(uint256(entry.topics[2])));
            receipt.purchaseRef = entry.topics[3];
            (receipt.receiptId, receipt.listingId, receipt.amount, receipt.metadataHash, receipt.agentId) =
                abi.decode(entry.data, (uint256, uint256, uint256, bytes32, bytes32));
            return receipt;
        }

        revert("no ReceiptPurchasedV2 event recorded");
    }

    function _assertRegistryConsumption(bytes32 ref, address expectedConsumer) internal view {
        (address consumer, uint64 consumedAt) = registry.consumptions(ref);

        assertEq(consumer, expectedConsumer);
        assertEq(registry.consumedBy(ref), expectedConsumer);
        assertTrue(registry.isConsumed(ref));
        assertGt(uint256(consumedAt), 0);
    }

    function _assertRegistryNotConsumed(bytes32 ref) internal view {
        (address consumer, uint64 consumedAt) = registry.consumptions(ref);

        assertEq(consumer, address(0));
        assertEq(uint256(consumedAt), 0);
        assertEq(registry.consumedBy(ref), address(0));
        assertFalse(registry.isConsumed(ref));
    }

    function _expectOnlyOwnerRevert(address caller) internal {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
    }

    function test_PurchaseRefRegistry_ConsumesPurchaseRefOnce() public {
        _authorizeRegistryConsumer(registry, address(this));
        registry.consume(purchaseRef);

        _assertRegistryConsumption(purchaseRef, address(this));

        vm.expectRevert(
            abi.encodeWithSelector(PurchaseRefRegistry.PurchaseRefAlreadyConsumed.selector, purchaseRef, address(this))
        );
        registry.consume(purchaseRef);
    }

    function test_PurchaseRefRegistry_RejectsZeroPurchaseRef() public {
        _authorizeRegistryConsumer(registry, address(this));
        vm.expectRevert(PurchaseRefRegistry.InvalidPurchaseRef.selector);
        registry.consume(bytes32(0));
    }

    function test_PurchaseRefRegistry_InitialStateIsEmpty() public view {
        (address consumer, uint64 consumedAt) = registry.consumptions(purchaseRef);

        assertFalse(registry.isConsumed(purchaseRef));
        assertEq(registry.consumedBy(purchaseRef), address(0));
        assertEq(consumer, address(0));
        assertEq(uint256(consumedAt), 0);
    }

    function test_PurchaseRefRegistry_ConsumeEmitsEvent() public {
        uint64 expectedConsumedAt = uint64(block.timestamp);
        _authorizeRegistryConsumer(registry, buyer);

        vm.expectEmit(true, true, false, true);
        emit PurchaseRefRegistry.PurchaseRefConsumed(purchaseRef, buyer, expectedConsumedAt);

        vm.prank(buyer);
        registry.consume(purchaseRef);

        _assertRegistryConsumption(purchaseRef, buyer);
    }

    function test_PurchaseRefRegistry_DifferentCallersCannotConsumeSameRef() public {
        _authorizeRegistryConsumer(registry, buyer);
        _authorizeRegistryConsumer(registry, buyer2);
        vm.prank(buyer);
        registry.consume(purchaseRef);

        vm.prank(buyer2);
        vm.expectRevert(
            abi.encodeWithSelector(PurchaseRefRegistry.PurchaseRefAlreadyConsumed.selector, purchaseRef, buyer)
        );
        registry.consume(purchaseRef);
    }

    function test_PurchaseRefRegistry_DifferentRefsCanBeConsumedBySameCaller() public {
        _authorizeRegistryConsumer(registry, buyer);
        vm.startPrank(buyer);
        registry.consume(purchaseRef);
        registry.consume(purchaseRef2);
        vm.stopPrank();

        _assertRegistryConsumption(purchaseRef, buyer);
        _assertRegistryConsumption(purchaseRef2, buyer);
    }

    function test_PurchaseRefRegistry_ConsumedAtUsesBlockTimestamp() public {
        uint64 expectedConsumedAt = 1_717_171_717;
        vm.warp(expectedConsumedAt);
        _authorizeRegistryConsumer(registry, buyer);

        vm.prank(buyer);
        registry.consume(purchaseRef);

        (, uint64 consumedAt) = registry.consumptions(purchaseRef);
        assertEq(consumedAt, expectedConsumedAt);
    }

    function test_ListingCreated_Emits() public {
        vm.expectEmit(true, true, true, true);
        emit NotaReceiptStore.ListingCreated(
            1, seller, listingHash, unitPrice, NotaReceiptStore.ListingMode.PublicFixedPrice
        );

        vm.prank(seller);
        store.createListing(listingHash, unitPrice, NotaReceiptStore.ListingMode.PublicFixedPrice);
    }

    function test_CreateListing_SetsFields() public {
        assertEq(store.listingCountBySeller(seller), 0);

        uint256 listingId = _createListingAsSeller();

        NotaReceiptStore.Listing memory listing = store.getListing(listingId);
        assertEq(listing.seller, seller);
        assertEq(listing.listingHash, listingHash);
        assertEq(listing.unitPrice, unitPrice);
        assertEq(listing.active, true);
        assertEq(uint8(listing.mode), uint8(NotaReceiptStore.ListingMode.PublicFixedPrice));

        (
            address listingSeller,
            bytes32 storedListingHash,
            uint256 listingUnitPrice,
            bool listingActive,
            NotaReceiptStore.ListingMode listingMode
        ) = store.listings(listingId);
        assertEq(listingSeller, seller);
        assertEq(storedListingHash, listingHash);
        assertEq(listingUnitPrice, unitPrice);
        assertEq(listingActive, true);
        assertEq(uint8(listingMode), uint8(NotaReceiptStore.ListingMode.PublicFixedPrice));
        assertEq(store.listingCountBySeller(seller), 1);
    }

    function test_ListingCountBySeller_StartsAtZero() public view {
        assertEq(store.listingCountBySeller(seller), 0);
        assertEq(store.listingCountBySeller(seller2), 0);
    }

    function test_ListingCountBySeller_IncrementsAfterCreateListing() public {
        assertEq(store.listingCountBySeller(seller), 0);

        uint256 listingId1 = _createListingAsSeller();
        uint256 listingId2 = _createListingAs(seller, listingHash2);

        assertEq(listingId1, 1);
        assertEq(listingId2, 2);
        assertEq(store.listingCountBySeller(seller), 2);
        assertEq(store.listingCountBySeller(seller2), 0);
    }

    function test_CreateListing_ZeroListingHashReverts() public {
        vm.prank(seller);
        vm.expectRevert(NotaReceiptStore.InvalidParams.selector);
        store.createListing(bytes32(0), unitPrice, NotaReceiptStore.ListingMode.PublicFixedPrice);
    }

    function test_CreateListing_UnitPriceBelowMinReverts() public {
        uint256 belowMin = store.MIN_PURCHASE_AMOUNT() - 1;

        vm.prank(seller);
        vm.expectRevert(NotaReceiptStore.AmountOutOfBounds.selector);
        store.createListing(listingHash, belowMin, NotaReceiptStore.ListingMode.PublicFixedPrice);
    }

    function test_CreateListing_UnitPriceAtMinSucceeds() public {
        uint256 listingId = _createListingAsSeller(store.MIN_PURCHASE_AMOUNT());
        assertEq(store.getListing(listingId).unitPrice, store.MIN_PURCHASE_AMOUNT());
    }

    function test_CreateListing_LargeUnitPriceSucceeds() public {
        uint256 listingId = _createListingAsSeller(largePurchaseAmount);
        assertEq(store.getListing(listingId).unitPrice, largePurchaseAmount);
    }

    // -------------------------------------------------------------------------
    // Listing mode behavior
    // -------------------------------------------------------------------------

    function test_CreateListing_PublicFixedPrice_ValidUnitPriceSucceeds() public {
        uint256 listingId =
            _createListingAs(store, seller, listingHash, unitPrice, NotaReceiptStore.ListingMode.PublicFixedPrice);

        NotaReceiptStore.Listing memory listing = store.getListing(listingId);
        assertEq(uint8(listing.mode), uint8(NotaReceiptStore.ListingMode.PublicFixedPrice));
        assertEq(listing.unitPrice, unitPrice);
    }

    function test_CreateListing_PublicFixedPrice_ZeroUnitPriceRevertsAmountOutOfBounds() public {
        vm.prank(seller);
        vm.expectRevert(NotaReceiptStore.AmountOutOfBounds.selector);
        store.createListing(listingHash, 0, NotaReceiptStore.ListingMode.PublicFixedPrice);
    }

    function test_CreateListing_SignedQuoteOnly_ZeroUnitPriceSucceeds() public {
        uint256 listingId =
            _createListingAs(store, seller, listingHash, 0, NotaReceiptStore.ListingMode.SignedQuoteOnly);

        NotaReceiptStore.Listing memory listing = store.getListing(listingId);
        assertEq(uint8(listing.mode), uint8(NotaReceiptStore.ListingMode.SignedQuoteOnly));
        assertEq(listing.unitPrice, 0);
    }

    function test_CreateListing_SignedQuoteOnly_NonZeroUnitPriceRevertsInvalidParams() public {
        vm.prank(seller);
        vm.expectRevert(NotaReceiptStore.InvalidParams.selector);
        store.createListing(listingHash, unitPrice, NotaReceiptStore.ListingMode.SignedQuoteOnly);
    }

    function test_PurchaseReceipt_PublicFixedPrice_Succeeds() public {
        uint256 listingId =
            _createListingAs(store, seller, listingHash, unitPrice, NotaReceiptStore.ListingMode.PublicFixedPrice);

        uint256 receiptId = _purchaseReceiptAs(listingId, buyer, purchaseRef);

        assertEq(receiptId, 1);
        assertEq(_lastEmittedReceipt().amount, unitPrice);
        _assertRegistryConsumption(purchaseRef, address(store));
    }

    function test_PurchaseReceipt_SignedQuoteOnly_RevertsListingRequiresSignedQuote() public {
        uint256 listingId =
            _createListingAs(store, seller, listingHash, 0, NotaReceiptStore.ListingMode.SignedQuoteOnly);

        vm.startPrank(buyer);
        usdc.approve(address(store), unitPrice);
        vm.expectRevert(NotaReceiptStore.ListingRequiresSignedQuote.selector);
        store.purchaseReceipt(listingId, purchaseRef, unitPrice);
        vm.stopPrank();

        _assertRegistryNotConsumed(purchaseRef);
    }

    function test_PurchaseSignedReceipt_PublicFixedPrice_Succeeds() public {
        uint256 listingId =
            _createListingAs(store, seller, listingHash, unitPrice, NotaReceiptStore.ListingMode.PublicFixedPrice);

        NotaReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 hours));
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        uint256 receiptId = _purchaseSignedReceiptAs(store, buyer, quote, signature);

        assertEq(receiptId, 1);
        assertEq(_lastEmittedReceipt().amount, quotedAmount);
        _assertRegistryConsumption(purchaseRef, address(store));
    }

    function test_PurchaseSignedReceipt_PublicFixedPrice_QuoteAmountOverridesUnitPrice() public {
        // A signed quote expresses seller-authorized commerce intent: it can settle a public
        // fixed-price listing at a different (here discounted) amount than the on-chain unitPrice,
        // proving signed quotes are not just a duplicate of the direct fixed-price purchase path.
        uint256 fixedUnitPrice = 10_000_000; // 10 USDC
        uint256 quoteAmount = 8_000_000; // 8 USDC

        uint256 listingId =
            _createListingAs(store, seller, listingHash, fixedUnitPrice, NotaReceiptStore.ListingMode.PublicFixedPrice);

        NotaReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quoteAmount, uint64(block.timestamp + 1 hours));
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        _purchaseSignedReceiptAs(store, buyer, quote, signature);

        assertEq(_lastEmittedReceipt().amount, quoteAmount);
    }

    function test_PurchaseSignedReceipt_SignedQuoteOnly_Succeeds() public {
        uint256 listingId =
            _createListingAs(store, seller, listingHash, 0, NotaReceiptStore.ListingMode.SignedQuoteOnly);

        NotaReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 hours));
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        uint256 receiptId = _purchaseSignedReceiptAs(store, buyer, quote, signature);

        assertEq(receiptId, 1);
        EmittedReceipt memory receipt = _lastEmittedReceipt();
        assertEq(receipt.buyer, buyer);
        assertEq(receipt.amount, quotedAmount);
        assertEq(receipt.purchaseRef, purchaseRef);
        _assertRegistryConsumption(purchaseRef, address(store));
    }

    function test_QuotePurchaseReceipt_PublicFixedPrice_Succeeds() public {
        uint256 listingId =
            _createListingAs(store, seller, listingHash, unitPrice, NotaReceiptStore.ListingMode.PublicFixedPrice);

        (uint256 grossAmount, uint256 protocolFee, uint256 sellerNet, address quotedFeeRecipient) =
            store.quotePurchaseReceipt(listingId);

        assertEq(grossAmount, unitPrice);
        assertEq(protocolFee, 0);
        assertEq(sellerNet, unitPrice);
        assertEq(quotedFeeRecipient, feeRecipient);
    }

    function test_QuotePurchaseReceipt_SignedQuoteOnly_RevertsListingRequiresSignedQuote() public {
        uint256 listingId =
            _createListingAs(store, seller, listingHash, 0, NotaReceiptStore.ListingMode.SignedQuoteOnly);

        vm.expectRevert(NotaReceiptStore.ListingRequiresSignedQuote.selector);
        store.quotePurchaseReceipt(listingId);
    }

    function test_Constructor_SucceedsWithValidOwner() public {
        address configuredOwner = address(0xA11CE123);

        NotaReceiptStore ownedStore =
            new NotaReceiptStore(address(usdc), address(registry), feeRecipient, 0, configuredOwner);

        assertEq(ownedStore.owner(), configuredOwner);
    }

    function test_Constructor_InvalidParamsRevert() public {
        vm.expectRevert(NotaReceiptStore.InvalidParams.selector);
        new NotaReceiptStore(address(0), address(registry), feeRecipient, 0, address(this));

        vm.expectRevert(NotaReceiptStore.InvalidParams.selector);
        new NotaReceiptStore(address(usdc), address(registry), address(0), 1, address(this));

        vm.expectRevert(NotaReceiptStore.InvalidParams.selector);
        new NotaReceiptStore(address(usdc), address(registry), feeRecipient, 51, address(this));

        vm.expectRevert(NotaReceiptStore.InvalidParams.selector);
        new NotaReceiptStore(address(usdc), address(0), feeRecipient, 0, address(this));
    }

    function test_Constructor_AcceptsMaxProtocolFeeBps() public {
        NotaReceiptStore feeStore =
            new NotaReceiptStore(address(usdc), address(registry), feeRecipient, 50, address(this));

        assertEq(feeStore.PROTOCOL_FEE_BPS(), 50);
    }

    function test_Constructor_ZeroOwnerReverts() public {
        vm.expectRevert(NotaReceiptStore.InvalidParams.selector);
        new NotaReceiptStore(address(usdc), address(registry), feeRecipient, 0, address(0));
    }

    function test_Constructor_AllowsZeroFeeRecipientWhenFeeDisabled() public {
        NotaReceiptStore zeroFeeStore =
            new NotaReceiptStore(address(usdc), address(registry), address(0), 0, address(this));

        assertEq(address(zeroFeeStore.SETTLEMENT_TOKEN()), address(usdc));
        assertEq(address(zeroFeeStore.PURCHASE_REF_REGISTRY()), address(registry));
        assertEq(zeroFeeStore.FEE_RECIPIENT(), address(0));
        assertEq(zeroFeeStore.PROTOCOL_FEE_BPS(), 0);
    }

    function test_Owner_ReturnsConfiguredOwner() public view {
        assertEq(store.owner(), address(this));
    }

    function test_Ownable2Step_TransferOwnershipRequiresAcceptance() public {
        address newOwner = address(0xB055);

        store.transferOwnership(newOwner);

        assertEq(store.owner(), address(this));
        assertEq(store.pendingOwner(), newOwner);

        vm.prank(newOwner);
        store.acceptOwnership();

        assertEq(store.owner(), newOwner);
        assertEq(store.pendingOwner(), address(0));
    }

    function test_PauseSetters_NonOwnerReverts() public {
        vm.startPrank(attacker);
        _expectOnlyOwnerRevert(attacker);
        store.setListingCreationPaused(true);

        _expectOnlyOwnerRevert(attacker);
        store.setPurchasesPaused(true);

        _expectOnlyOwnerRevert(attacker);
        store.setQuoteSignerUpdatesPaused(true);
        vm.stopPrank();
    }

    function test_PauseSetters_OwnerCanUpdateAll() public {
        store.setListingCreationPaused(true);
        store.setPurchasesPaused(true);
        store.setQuoteSignerUpdatesPaused(true);

        assertTrue(store.listingCreationPaused());
        assertTrue(store.purchasesPaused());
        assertTrue(store.quoteSignerUpdatesPaused());
    }

    function test_PauseSetters_EmitEvents() public {
        vm.expectEmit(false, false, false, true);
        emit NotaReceiptStore.ListingCreationPauseChanged(true);
        store.setListingCreationPaused(true);

        vm.expectEmit(false, false, false, true);
        emit NotaReceiptStore.PurchasesPauseChanged(true);
        store.setPurchasesPaused(true);

        vm.expectEmit(false, false, false, true);
        emit NotaReceiptStore.QuoteSignerUpdatesPauseChanged(true);
        store.setQuoteSignerUpdatesPaused(true);
    }

    function test_EIP712Constants_AreExpected() public view {
        assertEq(store.EIP712_NAME(), "NotaReceiptStore");
        assertEq(store.EIP712_VERSION(), "2");
        assertEq(
            store.SIGNED_RECEIPT_QUOTE_TYPEHASH(),
            keccak256(
                "SignedReceiptQuote(uint256 listingId,address seller,address buyer,bytes32 purchaseRef,uint256 amount,bytes32 metadataHash,bytes32 agentId,address settlementToken,address purchaseRefRegistry,address integratorFeeRecipient,uint256 integratorFeeAmount,uint64 issuedAt,uint64 expiresAt)"
            )
        );
    }

    function test_FeeCaps_AreExpected() public view {
        assertEq(store.MAX_PROTOCOL_FEE_BPS(), 50);
        assertEq(store.MAX_INTEGRATOR_FEE_BPS(), 450);
        assertEq(store.MAX_PROTOCOL_FEE_BPS() + store.MAX_INTEGRATOR_FEE_BPS(), 500);
    }

    function test_ListingCreationPause_BlocksNewListings() public {
        store.setListingCreationPaused(true);

        vm.prank(seller);
        vm.expectRevert(NotaReceiptStore.ListingCreationPaused.selector);
        store.createListing(listingHash, unitPrice, NotaReceiptStore.ListingMode.PublicFixedPrice);
    }

    function test_ListingCreationPause_DoesNotBlockExistingPurchases() public {
        uint256 listingId = _createListingAsSeller();

        store.setListingCreationPaused(true);

        uint256 receiptId = _purchaseReceiptAs(listingId, buyer, purchaseRef);
        assertEq(receiptId, 1);
    }

    function test_ListingCreationPause_UnpauseRestoresCreateListing() public {
        store.setListingCreationPaused(true);
        store.setListingCreationPaused(false);

        uint256 listingId = _createListingAsSeller();
        assertEq(listingId, 1);
    }

    function test_CreateListing_EnforcesListingCapPerSeller() public {
        uint256 maxListings = store.MAX_LISTINGS_PER_SELLER();

        for (uint256 i; i < maxListings; ++i) {
            uint256 listingId = _createListingAs(seller, _makeListingHash(i));
            assertEq(listingId, i + 1);
        }

        assertEq(store.listingCountBySeller(seller), maxListings);

        vm.prank(seller);
        vm.expectRevert(NotaReceiptStore.SellerListingLimitReached.selector);
        store.createListing(_makeListingHash(maxListings), unitPrice, NotaReceiptStore.ListingMode.PublicFixedPrice);

        uint256 seller2ListingId = _createListingAs(seller2, _makeListingHash(maxListings + 1));
        assertEq(seller2ListingId, maxListings + 1);
        assertEq(store.listingCountBySeller(seller), maxListings);
        assertEq(store.listingCountBySeller(seller2), 1);
    }

    function test_SetListingActive_TogglesAndBlocksPurchases() public {
        uint256 listingId = _createListingAsSeller();

        vm.expectEmit(true, true, false, true);
        emit NotaReceiptStore.ListingStatusChanged(listingId, seller, false);

        vm.prank(seller);
        store.setListingActive(listingId, false);

        vm.startPrank(buyer);
        usdc.approve(address(store), unitPrice);
        vm.expectRevert(NotaReceiptStore.ListingInactive.selector);
        store.purchaseReceipt(listingId, purchaseRef, unitPrice);
        vm.stopPrank();

        vm.prank(seller);
        store.setListingActive(listingId, true);

        uint256 receiptId = _purchaseReceiptAs(listingId, buyer, purchaseRef);
        assertEq(receiptId, 1);
    }

    function test_SetListingActive_NonSellerReverts() public {
        uint256 listingId = _createListingAsSeller();

        vm.prank(attacker);
        vm.expectRevert(NotaReceiptStore.NotListingSeller.selector);
        store.setListingActive(listingId, false);
    }

    function test_SetListingQuoteSigner_AuthorizesSigner() public {
        uint256 listingId = _createListingAsSeller();

        vm.expectEmit(true, true, true, true);
        emit NotaReceiptStore.QuoteSignerAuthorizationChanged(listingId, seller, quoteSigner, true);

        vm.prank(seller);
        store.setListingQuoteSigner(listingId, quoteSigner, true);

        assertEq(store.authorizedQuoteSigners(listingId, quoteSigner), true);
        assertEq(store.authorizedQuoteSignerCount(listingId), 1);
    }

    function test_SetListingQuoteSigner_IsScopedToListing() public {
        uint256 listingId = _createListingAsSeller();
        uint256 otherListingId = _createListingAs(seller, listingHash2);

        vm.prank(seller);
        store.setListingQuoteSigner(listingId, quoteSigner, true);

        assertEq(store.authorizedQuoteSigners(listingId, quoteSigner), true);
        assertEq(store.authorizedQuoteSigners(otherListingId, quoteSigner), false);
        assertEq(store.authorizedQuoteSignerCount(listingId), 1);
        assertEq(store.authorizedQuoteSignerCount(otherListingId), 0);
    }

    function test_IsQuoteSignerAuthorized_ReturnsSellerAndDelegatedSignerStatus() public {
        uint256 listingId = _createListingAsSeller();
        uint256 otherListingId = _createListingAs(seller, listingHash2);

        assertTrue(store.isQuoteSignerAuthorized(listingId, seller));
        assertFalse(store.isQuoteSignerAuthorized(listingId, quoteSigner));

        vm.prank(seller);
        store.setListingQuoteSigner(listingId, quoteSigner, true);

        assertTrue(store.isQuoteSignerAuthorized(listingId, quoteSigner));
        assertFalse(store.isQuoteSignerAuthorized(otherListingId, quoteSigner));
        assertTrue(store.isQuoteSignerAuthorized(otherListingId, seller));
    }

    function test_IsQuoteSignerAuthorized_NonexistentListingReverts() public {
        vm.expectRevert(NotaReceiptStore.ListingNotFound.selector);
        store.isQuoteSignerAuthorized(999, quoteSigner);
    }

    function test_SetListingQuoteSigner_NonListingSellerReverts() public {
        uint256 listingId = _createListingAsSeller();

        vm.prank(seller2);
        vm.expectRevert(NotaReceiptStore.NotListingSeller.selector);
        store.setListingQuoteSigner(listingId, quoteSigner, true);
    }

    function test_SetListingQuoteSigner_RevokesSigner() public {
        uint256 listingId = _createListingAsSeller();
        _setListingQuoteSigner(store, seller, listingId, quoteSigner, true);

        vm.expectEmit(true, true, true, true);
        emit NotaReceiptStore.QuoteSignerAuthorizationChanged(listingId, seller, quoteSigner, false);

        vm.prank(seller);
        store.setListingQuoteSigner(listingId, quoteSigner, false);

        assertEq(store.authorizedQuoteSigners(listingId, quoteSigner), false);
        assertEq(store.authorizedQuoteSignerCount(listingId), 0);
    }

    function test_SetListingQuoteSigner_ZeroSignerRejected() public {
        uint256 listingId = _createListingAsSeller();

        vm.prank(seller);
        vm.expectRevert(NotaReceiptStore.InvalidParams.selector);
        store.setListingQuoteSigner(listingId, address(0), true);
    }

    function test_SetListingQuoteSigner_SelfAuthorizationRejected() public {
        uint256 listingId = _createListingAsSeller();

        vm.prank(seller);
        vm.expectRevert(NotaReceiptStore.InvalidParams.selector);
        store.setListingQuoteSigner(listingId, seller, true);
    }

    function test_SetListingQuoteSigner_PauseBlocksUpdatesUntilUnpaused() public {
        uint256 listingId = _createListingAsSeller();

        store.setQuoteSignerUpdatesPaused(true);

        vm.prank(seller);
        vm.expectRevert(NotaReceiptStore.QuoteSignerUpdatesPaused.selector);
        store.setListingQuoteSigner(listingId, quoteSigner, true);

        store.setQuoteSignerUpdatesPaused(false);

        vm.prank(seller);
        store.setListingQuoteSigner(listingId, quoteSigner, true);

        assertTrue(store.authorizedQuoteSigners(listingId, quoteSigner));
        assertEq(store.authorizedQuoteSignerCount(listingId), 1);
    }

    function test_SetListingQuoteSigner_TracksCountAndEnforcesCap() public {
        uint256 listingId = _createListingAsSeller();
        uint256 seller2ListingId = _createListingAs(store, seller2, listingHash2);
        address signer1 = vm.addr(1001);
        address signer2 = vm.addr(1002);
        address signer3 = vm.addr(1003);
        address signer4 = vm.addr(1004);

        _setListingQuoteSigner(store, seller, listingId, signer1, true);
        _setListingQuoteSigner(store, seller, listingId, signer2, true);
        _setListingQuoteSigner(store, seller, listingId, signer3, true);

        assertEq(store.authorizedQuoteSignerCount(listingId), store.MAX_QUOTE_SIGNERS_PER_LISTING());

        vm.prank(seller);
        vm.expectRevert(NotaReceiptStore.QuoteSignerLimitReached.selector);
        store.setListingQuoteSigner(listingId, signer4, true);

        vm.prank(seller);
        store.setListingQuoteSigner(listingId, signer1, true);
        assertEq(store.authorizedQuoteSignerCount(listingId), store.MAX_QUOTE_SIGNERS_PER_LISTING());

        vm.prank(seller);
        store.setListingQuoteSigner(listingId, signer1, false);
        assertEq(store.authorizedQuoteSignerCount(listingId), store.MAX_QUOTE_SIGNERS_PER_LISTING() - 1);

        vm.prank(seller);
        store.setListingQuoteSigner(listingId, signer1, false);
        assertEq(store.authorizedQuoteSignerCount(listingId), store.MAX_QUOTE_SIGNERS_PER_LISTING() - 1);

        vm.prank(seller);
        store.setListingQuoteSigner(listingId, signer4, true);
        assertEq(store.authorizedQuoteSigners(listingId, signer4), true);
        assertEq(store.authorizedQuoteSignerCount(listingId), store.MAX_QUOTE_SIGNERS_PER_LISTING());

        _setListingQuoteSigner(store, seller2, seller2ListingId, signer1, true);
        assertEq(store.authorizedQuoteSignerCount(seller2ListingId), 1);
        assertEq(store.authorizedQuoteSignerCount(listingId), store.MAX_QUOTE_SIGNERS_PER_LISTING());
    }

    function test_SetListingQuoteSigner_DirectSellerSignatureStillWorksAtSignerCap() public {
        uint256 listingId = _createListingAsSeller();

        _setListingQuoteSigner(store, seller, listingId, vm.addr(1001), true);
        _setListingQuoteSigner(store, seller, listingId, vm.addr(1002), true);
        _setListingQuoteSigner(store, seller, listingId, vm.addr(1003), true);

        NotaReceiptStore.SignedReceiptQuote memory quote = _makeSignedReceiptQuote(
            listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + store.MAX_QUOTE_TTL())
        );
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        uint256 receiptId = _purchaseSignedReceiptAs(store, buyer, quote, signature);
        assertEq(receiptId, 1);
    }

    function test_PurchasesPause_BlocksPurchaseReceipt() public {
        uint256 listingId = _createListingAsSeller();

        store.setPurchasesPaused(true);

        vm.startPrank(buyer);
        usdc.approve(address(store), unitPrice);
        vm.expectRevert(NotaReceiptStore.PurchasesPaused.selector);
        store.purchaseReceipt(listingId, purchaseRef, unitPrice);
        vm.stopPrank();
    }

    function test_PurchasesPause_BlocksPurchaseSignedReceipt() public {
        uint256 listingId = _createListingAsSeller();
        NotaReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 hours));
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        store.setPurchasesPaused(true);

        vm.startPrank(buyer);
        usdc.approve(address(store), quotedAmount);
        vm.expectRevert(NotaReceiptStore.PurchasesPaused.selector);
        store.purchaseSignedReceipt(quote, signature, address(0));
        vm.stopPrank();
    }

    function test_PurchasesPause_AllowsSellerConfigAndGetters() public {
        uint256 listingId = _createListingAsSeller();

        store.setPurchasesPaused(true);

        vm.prank(seller);
        store.setListingActive(listingId, false);

        NotaReceiptStore.Listing memory listing = store.getListing(listingId);

        assertEq(listing.unitPrice, unitPrice);
        assertFalse(listing.active);
        // Deactivation releases the slot: the cap counts active listings, not created ones.
        assertEq(store.listingCountBySeller(seller), 0);
    }

    // -------------------------------------------------------------------------
    // Listing cap is a concurrency cap
    // -------------------------------------------------------------------------

    function test_SetListingActive_DeactivationReleasesCapSlot() public {
        uint256 listingId = _createListingAsSeller();
        assertEq(store.listingCountBySeller(seller), 1);

        vm.prank(seller);
        store.setListingActive(listingId, false);
        assertEq(store.listingCountBySeller(seller), 0);

        vm.prank(seller);
        store.setListingActive(listingId, true);
        assertEq(store.listingCountBySeller(seller), 1);
    }

    /// @dev A no-op must not move the counter in either direction.
    function test_SetListingActive_RedundantCallDoesNotMoveCount() public {
        uint256 listingId = _createListingAsSeller();

        vm.prank(seller);
        store.setListingActive(listingId, true);
        assertEq(store.listingCountBySeller(seller), 1);

        vm.startPrank(seller);
        store.setListingActive(listingId, false);
        store.setListingActive(listingId, false);
        vm.stopPrank();
        assertEq(store.listingCountBySeller(seller), 0);
    }

    /// @dev The point of the change: a seller who supersedes listings to change prices is not
    ///      permanently spending their budget. Fill the cap, deactivate one, create another.
    function test_CreateListing_DeactivatedListingFreesCapacityForANewOne() public {
        uint256 cap = store.MAX_LISTINGS_PER_SELLER();
        uint256 firstListingId;

        vm.startPrank(seller);
        for (uint256 i; i < cap; ++i) {
            uint256 id = store.createListing(
                keccak256(abi.encodePacked("cap-listing", i)), unitPrice, NotaReceiptStore.ListingMode.PublicFixedPrice
            );
            if (i == 0) firstListingId = id;
        }

        assertEq(store.listingCountBySeller(seller), cap);
        vm.expectRevert(NotaReceiptStore.SellerListingLimitReached.selector);
        store.createListing(keccak256("one-too-many"), unitPrice, NotaReceiptStore.ListingMode.PublicFixedPrice);

        store.setListingActive(firstListingId, false);
        store.createListing(keccak256("replacement"), unitPrice, NotaReceiptStore.ListingMode.PublicFixedPrice);
        vm.stopPrank();

        assertEq(store.listingCountBySeller(seller), cap);
    }

    /// @dev The trade for that: reactivating cannot exceed the cap either.
    function test_SetListingActive_ReactivationAtCapReverts() public {
        uint256 cap = store.MAX_LISTINGS_PER_SELLER();
        uint256 firstListingId;

        vm.startPrank(seller);
        for (uint256 i; i < cap; ++i) {
            uint256 id = store.createListing(
                keccak256(abi.encodePacked("cap-listing", i)), unitPrice, NotaReceiptStore.ListingMode.PublicFixedPrice
            );
            if (i == 0) firstListingId = id;
        }

        store.setListingActive(firstListingId, false);
        store.createListing(keccak256("replacement"), unitPrice, NotaReceiptStore.ListingMode.PublicFixedPrice);

        vm.expectRevert(NotaReceiptStore.SellerListingLimitReached.selector);
        store.setListingActive(firstListingId, true);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // renounceOwnership guard
    // -------------------------------------------------------------------------

    /// @dev Renouncing mid-pause would leave nobody able to unpause, stranding the contract with
    ///      no recovery path.
    function test_RenounceOwnership_RevertsWhilePurchasesPaused() public {
        store.setPurchasesPaused(true);

        vm.expectRevert(NotaReceiptStore.RenounceWhilePausedDisabled.selector);
        store.renounceOwnership();

        assertEq(store.owner(), address(this));
    }

    function test_RenounceOwnership_RevertsWhileListingCreationPaused() public {
        store.setListingCreationPaused(true);

        vm.expectRevert(NotaReceiptStore.RenounceWhilePausedDisabled.selector);
        store.renounceOwnership();

        assertEq(store.owner(), address(this));
    }

    function test_RenounceOwnership_RevertsWhileQuoteSignerUpdatesPaused() public {
        store.setQuoteSignerUpdatesPaused(true);

        vm.expectRevert(NotaReceiptStore.RenounceWhilePausedDisabled.selector);
        store.renounceOwnership();

        assertEq(store.owner(), address(this));
    }

    function test_RenounceOwnership_SucceedsWhenUnpaused() public {
        store.renounceOwnership();
        assertEq(store.owner(), address(0));
    }

    /// @dev Unpausing restores the ability to renounce, so the guard blocks the dangerous
    ///      ordering rather than the operation.
    function test_RenounceOwnership_AllowedAfterUnpausing() public {
        store.setPurchasesPaused(true);
        vm.expectRevert(NotaReceiptStore.RenounceWhilePausedDisabled.selector);
        store.renounceOwnership();

        store.setPurchasesPaused(false);
        store.renounceOwnership();
        assertEq(store.owner(), address(0));
    }

    function test_RenounceOwnership_NonOwnerRevertsWithOwnableError() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        store.renounceOwnership();
    }

    function test_PurchasesPause_UnpauseRestoresPurchases() public {
        uint256 listingId = _createListingAsSeller();

        store.setPurchasesPaused(true);
        store.setPurchasesPaused(false);

        uint256 fixedReceiptId = _purchaseReceiptAs(listingId, buyer, purchaseRef);
        assertEq(fixedReceiptId, 1);

        NotaReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer2, purchaseRef2, quotedAmount, uint64(block.timestamp + 1 hours));
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        uint256 signedReceiptId = _purchaseSignedReceiptAs(store, buyer2, quote, signature);
        assertEq(signedReceiptId, 2);
    }

    function test_PurchaseReceipt_SettlesImmediatelyAndEmitsReceipt() public {
        uint256 listingId = _createListingAsSeller();
        uint256 sellerBalanceBefore = usdc.balanceOf(seller);
        uint256 buyerBalanceBefore = usdc.balanceOf(buyer);
        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);

        _assertRegistryNotConsumed(purchaseRef);

        vm.startPrank(buyer);
        usdc.approve(address(store), unitPrice);

        vm.expectEmit(true, true, true, true);
        emit NotaReceiptStore.SellerPaid(1, listingId, seller, unitPrice);
        vm.expectEmit(true, true, true, true);
        emit NotaReceiptStore.ReceiptPurchasedV2(
            1, seller, buyer, listingId, purchaseRef, unitPrice, bytes32(0), bytes32(0)
        );

        uint256 receiptId = store.purchaseReceipt(listingId, purchaseRef, unitPrice);
        vm.stopPrank();

        assertEq(receiptId, 1);

        EmittedReceipt memory receipt = _lastEmittedReceipt();
        assertEq(receipt.listingId, listingId);
        assertEq(receipt.seller, seller);
        assertEq(receipt.buyer, buyer);
        assertEq(receipt.amount, unitPrice);
        assertEq(receipt.purchaseRef, purchaseRef);
        _assertRegistryConsumption(purchaseRef, address(store));
        assertEq(usdc.balanceOf(buyer), buyerBalanceBefore - unitPrice);
        assertEq(usdc.balanceOf(seller), sellerBalanceBefore + unitPrice);
        assertEq(usdc.balanceOf(feeRecipient), feeRecipientBalanceBefore);
        assertEq(usdc.balanceOf(address(store)), 0);
    }

    function test_PurchaseReceipt_WithCanonicalHashStoresReceiptAndMappings() public {
        uint256 listingId = _createListingAsSeller();
        string memory rawPurchaseRef = _makeRawPurchaseRef(5);
        bytes32 canonicalPurchaseRef = store.hashPurchaseRef(seller, listingId, rawPurchaseRef, purchaseRefNonce);

        _purchaseReceiptAs(listingId, buyer, canonicalPurchaseRef);

        EmittedReceipt memory receipt = _lastEmittedReceipt();
        assertEq(receipt.purchaseRef, canonicalPurchaseRef);
        _assertRegistryConsumption(canonicalPurchaseRef, address(store));
    }

    function test_PurchaseReceipt_EmitsPurchaseRefConsumedFromRegistry() public {
        uint256 listingId = _createListingAsSeller();

        vm.startPrank(buyer);
        usdc.approve(address(store), unitPrice);

        vm.expectEmit(true, true, false, true, address(registry));
        emit PurchaseRefRegistry.PurchaseRefConsumed(purchaseRef, address(store), uint64(block.timestamp));

        store.purchaseReceipt(listingId, purchaseRef, unitPrice);
        vm.stopPrank();
    }

    function test_PurchaseReceipt_PaysProtocolFeeAndSellerNet() public {
        NotaReceiptStore feeStore = _deployStore(50);
        uint256 listingId = _createListingAs(feeStore, seller, listingHash);
        address integrator = address(0x1A7E);
        uint256 sellerBalanceBefore = usdc.balanceOf(seller);
        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);
        uint256 integratorBalanceBefore = usdc.balanceOf(integrator);
        uint256 protocolFee = unitPrice * 50 / 10_000;

        vm.startPrank(buyer);
        usdc.approve(address(feeStore), unitPrice);

        vm.expectEmit(true, true, true, true);
        emit NotaReceiptStore.ProtocolFeePaid(1, listingId, feeRecipient, protocolFee);
        vm.expectEmit(true, true, true, true);
        emit NotaReceiptStore.SellerPaid(1, listingId, seller, unitPrice - protocolFee);
        vm.expectEmit(true, true, true, true);
        emit NotaReceiptStore.ReceiptPurchasedV2(
            1, seller, buyer, listingId, purchaseRef, unitPrice, bytes32(0), bytes32(0)
        );

        feeStore.purchaseReceipt(listingId, purchaseRef, unitPrice);
        vm.stopPrank();

        assertEq(usdc.balanceOf(feeRecipient), feeRecipientBalanceBefore + protocolFee);
        assertEq(usdc.balanceOf(integrator), integratorBalanceBefore);
        assertEq(usdc.balanceOf(seller), sellerBalanceBefore + (unitPrice - protocolFee));
        assertEq(usdc.balanceOf(address(feeStore)), 0);
    }

    function test_PurchaseReceipt_RevertsWhenAmountAboveListingPrice() public {
        uint256 listingId = _createListingAsSeller();

        vm.startPrank(buyer);
        usdc.approve(address(store), unitPrice + 1);
        vm.expectRevert(NotaReceiptStore.PriceMismatch.selector);
        store.purchaseReceipt(listingId, purchaseRef, unitPrice + 1);
        vm.stopPrank();

        _assertRegistryNotConsumed(purchaseRef);
    }

    function test_PurchaseReceipt_RevertsWhenAmountBelowListingPrice() public {
        uint256 listingId = _createListingAsSeller();

        vm.startPrank(buyer);
        usdc.approve(address(store), unitPrice);
        vm.expectRevert(NotaReceiptStore.PriceMismatch.selector);
        store.purchaseReceipt(listingId, purchaseRef, unitPrice - 1);
        vm.stopPrank();

        _assertRegistryNotConsumed(purchaseRef);
    }

    function test_PurchaseReceipt_RevertsWhenAmountIsZero() public {
        uint256 listingId = _createListingAsSeller();

        vm.startPrank(buyer);
        usdc.approve(address(store), unitPrice);
        vm.expectRevert(NotaReceiptStore.PriceMismatch.selector);
        store.purchaseReceipt(listingId, purchaseRef, 0);
        vm.stopPrank();
    }

    function test_PurchaseReceipt_ZeroPurchaseRefReverts() public {
        uint256 listingId = _createListingAsSeller();

        vm.startPrank(buyer);
        usdc.approve(address(store), unitPrice);
        vm.expectRevert(NotaReceiptStore.InvalidPurchaseRef.selector);
        store.purchaseReceipt(listingId, bytes32(0), unitPrice);
        vm.stopPrank();
    }

    function test_PurchaseReceipt_DuplicatePurchaseRefSameSellerReverts() public {
        uint256 listingId = _createListingAsSeller();

        _purchaseReceiptAs(listingId, buyer, purchaseRef);

        vm.startPrank(buyer2);
        usdc.approve(address(store), unitPrice);
        vm.expectRevert(NotaReceiptStore.PurchaseRefAlreadyUsed.selector);
        store.purchaseReceipt(listingId, purchaseRef, unitPrice);
        vm.stopPrank();
    }

    function test_PurchaseReceipt_CanonicalHashDuplicateSameSellerReverts() public {
        uint256 listingId = _createListingAsSeller();
        string memory rawPurchaseRef = _makeRawPurchaseRef(6);
        bytes32 canonicalPurchaseRef = store.hashPurchaseRef(seller, listingId, rawPurchaseRef, purchaseRefNonce);

        _purchaseReceiptAs(listingId, buyer, canonicalPurchaseRef);

        vm.startPrank(buyer2);
        usdc.approve(address(store), unitPrice);
        vm.expectRevert(NotaReceiptStore.PurchaseRefAlreadyUsed.selector);
        store.purchaseReceipt(listingId, canonicalPurchaseRef, unitPrice);
        vm.stopPrank();
    }

    function test_PurchaseReceipt_SameRawPurchaseRefAcrossListingsReverts() public {
        uint256 listingId1 = _createListingAs(seller, listingHash);
        uint256 listingId2 = _createListingAs(seller, listingHash2);
        string memory rawPurchaseRef = _makeRawPurchaseRef(7);
        bytes32 listing1PurchaseRef = store.hashPurchaseRef(seller, listingId1, rawPurchaseRef, purchaseRefNonce);
        bytes32 listing2PurchaseRef = store.hashPurchaseRef(seller, listingId2, rawPurchaseRef, purchaseRefNonce);

        assertEq(listing1PurchaseRef, listing2PurchaseRef);

        _purchaseReceiptAs(listingId1, buyer, listing1PurchaseRef);

        vm.startPrank(buyer2);
        usdc.approve(address(store), unitPrice);
        vm.expectRevert(NotaReceiptStore.PurchaseRefAlreadyUsed.selector);
        store.purchaseReceipt(listingId2, listing2PurchaseRef, unitPrice);
        vm.stopPrank();
    }

    function test_PurchaseReceipt_DifferentPurchaseRefsStillWork() public {
        uint256 listingId = _createListingAsSeller();

        uint256 receiptId1 = _purchaseReceiptAs(listingId, buyer, purchaseRef);
        uint256 receiptId2 = _purchaseReceiptAs(listingId, buyer2, purchaseRef2);

        assertEq(receiptId1, 1);
        assertEq(receiptId2, 2);
        _assertRegistryConsumption(purchaseRef, address(store));
        _assertRegistryConsumption(purchaseRef2, address(store));
        _assertRegistryConsumption(purchaseRef, address(store));
        _assertRegistryConsumption(purchaseRef2, address(store));
    }

    function test_PurchaseReceipt_PurchaseRefReplayAcrossListingsReverts() public {
        uint256 listingId1 = _createListingAs(seller, listingHash);
        uint256 listingId2 = _createListingAs(seller, listingHash2);

        _purchaseReceiptAs(listingId1, buyer, purchaseRef);

        vm.startPrank(buyer2);
        usdc.approve(address(store), unitPrice);
        vm.expectRevert(NotaReceiptStore.PurchaseRefAlreadyUsed.selector);
        store.purchaseReceipt(listingId2, purchaseRef, unitPrice);
        vm.stopPrank();
    }

    function test_PurchaseReceipt_PurchaseRefReplayAcrossDifferentSellersReverts() public {
        uint256 listingId1 = _createListingAs(seller, listingHash);
        uint256 listingId2 = _createListingAs(seller2, listingHash2);

        uint256 receiptId1 = _purchaseReceiptAs(listingId1, buyer, purchaseRef);

        assertEq(receiptId1, 1);
        _assertRegistryConsumption(purchaseRef, address(store));

        vm.startPrank(buyer2);
        usdc.approve(address(store), unitPrice);
        vm.expectRevert(NotaReceiptStore.PurchaseRefAlreadyUsed.selector);
        store.purchaseReceipt(listingId2, purchaseRef, unitPrice);
        vm.stopPrank();
    }

    function test_PurchaseReceipt_FailedTransferDoesNotConsumeRegistry() public {
        uint256 listingId = _createListingAsSeller();

        vm.prank(buyer);
        vm.expectRevert();
        store.purchaseReceipt(listingId, purchaseRef, unitPrice);

        _assertRegistryNotConsumed(purchaseRef);
    }

    /// @dev A ref consumed by a different authorized consumer still blocks this store. The
    ///      registry is the only replay barrier now that no per-store receipt record exists.
    function test_RegistryBlocksPurchaseOfRefConsumedByAnotherConsumer() public {
        uint256 listingId = _createListingAsSeller();
        address externalConsumer = address(0xBAD);
        _authorizeRegistryConsumer(registry, externalConsumer);

        vm.prank(externalConsumer);
        registry.consume(purchaseRef);

        assertEq(registry.consumedBy(purchaseRef), externalConsumer);

        vm.startPrank(buyer);
        usdc.approve(address(store), unitPrice);
        vm.expectRevert(NotaReceiptStore.PurchaseRefAlreadyUsed.selector);
        store.purchaseReceipt(listingId, purchaseRef, unitPrice);
        vm.stopPrank();
    }

    function test_PurchaseReceipt_NonexistentListingReverts() public {
        vm.startPrank(buyer);
        usdc.approve(address(store), unitPrice);
        vm.expectRevert(NotaReceiptStore.ListingNotFound.selector);
        store.purchaseReceipt(999, purchaseRef, unitPrice);
        vm.stopPrank();
    }

    function test_PurchaseReceipt_RevertsWhenStoreNotAuthorizedInRegistry() public {
        PurchaseRefRegistry unauthorizedRegistry = new PurchaseRefRegistry(address(this));
        NotaReceiptStore unauthorizedStore =
            new NotaReceiptStore(address(usdc), address(unauthorizedRegistry), feeRecipient, 0, address(this));
        uint256 listingId = _createListingAs(unauthorizedStore, seller, listingHash);

        vm.startPrank(buyer);
        usdc.approve(address(unauthorizedStore), unitPrice);
        vm.expectRevert(
            abi.encodeWithSelector(PurchaseRefRegistry.UnauthorizedConsumer.selector, address(unauthorizedStore))
        );
        unauthorizedStore.purchaseReceipt(listingId, purchaseRef, unitPrice);
        vm.stopPrank();
    }

    function test_PurchaseSignedReceipt_ListingAuthorizedSignerCanSignQuote() public {
        NotaReceiptStore feeStore = _deployStore(50);
        uint256 listingId = _createListingAs(feeStore, seller, listingHash);
        _setListingQuoteSigner(feeStore, seller, listingId, quoteSigner, true);

        NotaReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 days));
        bytes memory signature = _signSignedReceiptQuote(feeStore, QUOTE_SIGNER_PK, quote);
        uint256 sellerBalanceBefore = usdc.balanceOf(seller);
        uint256 buyerBalanceBefore = usdc.balanceOf(buyer);
        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);
        uint256 protocolFee = quotedAmount * 50 / 10_000;

        vm.startPrank(buyer);
        usdc.approve(address(feeStore), quotedAmount);

        vm.expectEmit(true, true, true, true);
        emit NotaReceiptStore.ProtocolFeePaid(1, listingId, feeRecipient, protocolFee);
        vm.expectEmit(true, true, true, true);
        emit NotaReceiptStore.SellerPaid(1, listingId, seller, quotedAmount - protocolFee);
        vm.expectEmit(true, true, true, true);
        emit NotaReceiptStore.ReceiptPurchasedV2(
            1, seller, buyer, listingId, purchaseRef, quotedAmount, metadataHash, bytes32(0)
        );

        uint256 receiptId = feeStore.purchaseSignedReceipt(quote, signature, quoteSigner);
        vm.stopPrank();

        EmittedReceipt memory receipt = _lastEmittedReceipt();
        assertEq(receiptId, 1);
        assertEq(receipt.amount, quotedAmount);
        assertEq(receipt.buyer, buyer);
        assertEq(receipt.seller, seller);
        assertEq(receipt.purchaseRef, purchaseRef);
        _assertRegistryConsumption(purchaseRef, address(feeStore));
        assertEq(usdc.balanceOf(buyer), buyerBalanceBefore - quotedAmount);
        assertEq(usdc.balanceOf(seller), sellerBalanceBefore + (quotedAmount - protocolFee));
        assertEq(usdc.balanceOf(feeRecipient), feeRecipientBalanceBefore + protocolFee);
        assertEq(usdc.balanceOf(address(feeStore)), 0);
    }

    function test_PurchaseSignedReceipt_RevertsWhenStoreNotAuthorizedInRegistry() public {
        PurchaseRefRegistry unauthorizedRegistry = new PurchaseRefRegistry(address(this));
        NotaReceiptStore unauthorizedStore =
            new NotaReceiptStore(address(usdc), address(unauthorizedRegistry), feeRecipient, 0, address(this));
        uint256 listingId = _createListingAs(unauthorizedStore, seller, listingHash);
        NotaReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 days));
        bytes memory signature = _signSignedReceiptQuote(unauthorizedStore, SELLER_PK, quote);

        vm.startPrank(buyer);
        usdc.approve(address(unauthorizedStore), quotedAmount);
        vm.expectRevert(
            abi.encodeWithSelector(PurchaseRefRegistry.UnauthorizedConsumer.selector, address(unauthorizedStore))
        );
        unauthorizedStore.purchaseSignedReceipt(quote, signature, address(0));
        vm.stopPrank();
    }

    function test_PurchaseSignedReceipt_DirectSellerSignatureStillWorks() public {
        NotaReceiptStore feeStore = _deployStore(50);
        uint256 listingId = _createListingAs(feeStore, seller, listingHash);
        address integrator = address(0x1A7E);
        assertFalse(feeStore.authorizedQuoteSigners(listingId, seller));
        assertEq(feeStore.authorizedQuoteSignerCount(listingId), 0);
        NotaReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 days));
        bytes memory signature = _signSignedReceiptQuote(feeStore, SELLER_PK, quote);
        uint256 sellerBalanceBefore = usdc.balanceOf(seller);
        uint256 buyerBalanceBefore = usdc.balanceOf(buyer);
        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);
        uint256 integratorBalanceBefore = usdc.balanceOf(integrator);
        uint256 protocolFee = quotedAmount * 50 / 10_000;

        vm.startPrank(buyer);
        usdc.approve(address(feeStore), quotedAmount);

        vm.expectEmit(true, true, true, true);
        emit NotaReceiptStore.ProtocolFeePaid(1, listingId, feeRecipient, protocolFee);
        vm.expectEmit(true, true, true, true);
        emit NotaReceiptStore.SellerPaid(1, listingId, seller, quotedAmount - protocolFee);
        vm.expectEmit(true, true, true, true);
        emit NotaReceiptStore.ReceiptPurchasedV2(
            1, seller, buyer, listingId, purchaseRef, quotedAmount, metadataHash, bytes32(0)
        );

        uint256 receiptId = feeStore.purchaseSignedReceipt(quote, signature, address(0));
        vm.stopPrank();

        EmittedReceipt memory receipt = _lastEmittedReceipt();
        assertEq(receiptId, 1);
        assertEq(receipt.amount, quotedAmount);
        assertEq(receipt.buyer, buyer);
        assertEq(receipt.seller, seller);
        assertEq(receipt.purchaseRef, purchaseRef);
        _assertRegistryConsumption(purchaseRef, address(feeStore));
        assertEq(usdc.balanceOf(buyer), buyerBalanceBefore - quotedAmount);
        assertEq(usdc.balanceOf(seller), sellerBalanceBefore + (quotedAmount - protocolFee));
        assertEq(usdc.balanceOf(feeRecipient), feeRecipientBalanceBefore + protocolFee);
        assertEq(usdc.balanceOf(integrator), integratorBalanceBefore);
        assertEq(usdc.balanceOf(address(feeStore)), 0);
        assertFalse(feeStore.authorizedQuoteSigners(listingId, seller));
        assertEq(feeStore.authorizedQuoteSignerCount(listingId), 0);
    }

    function test_PurchaseSignedReceipt_PaysIntegratorFeeAndSellerNet() public {
        NotaReceiptStore feeStore = _deployStore(50);
        uint256 listingId = _createListingAs(feeStore, seller, listingHash);
        address integrator = address(0x1A7E);
        uint256 integratorFeeAmount = quotedAmount * 200 / 10_000;
        NotaReceiptStore.SignedReceiptQuote memory quote = _makeSignedReceiptQuoteWithIntegrator(
            listingId,
            buyer,
            purchaseRef,
            quotedAmount,
            integrator,
            integratorFeeAmount,
            uint64(block.timestamp + 1 days)
        );
        bytes memory signature = _signSignedReceiptQuote(feeStore, SELLER_PK, quote);
        uint256 sellerBalanceBefore = usdc.balanceOf(seller);
        uint256 buyerBalanceBefore = usdc.balanceOf(buyer);
        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);
        uint256 integratorBalanceBefore = usdc.balanceOf(integrator);
        uint256 protocolFee = quotedAmount * 50 / 10_000;

        vm.startPrank(buyer);
        usdc.approve(address(feeStore), quotedAmount);

        vm.expectEmit(true, true, true, true);
        emit NotaReceiptStore.ProtocolFeePaid(1, listingId, feeRecipient, protocolFee);
        vm.expectEmit(true, true, true, true);
        emit NotaReceiptStore.IntegratorFeePaid(1, listingId, integrator, integratorFeeAmount);
        vm.expectEmit(true, true, true, true);
        emit NotaReceiptStore.SellerPaid(1, listingId, seller, quotedAmount - protocolFee - integratorFeeAmount);
        vm.expectEmit(true, true, true, true);
        emit NotaReceiptStore.ReceiptPurchasedV2(
            1, seller, buyer, listingId, purchaseRef, quotedAmount, metadataHash, bytes32(0)
        );

        uint256 receiptId = feeStore.purchaseSignedReceipt(quote, signature, address(0));
        vm.stopPrank();

        EmittedReceipt memory receipt = _lastEmittedReceipt();
        assertEq(receiptId, 1);
        assertEq(receipt.amount, quotedAmount);
        assertEq(receipt.buyer, buyer);
        assertEq(receipt.seller, seller);
        assertEq(receipt.purchaseRef, purchaseRef);
        assertEq(usdc.balanceOf(buyer), buyerBalanceBefore - quotedAmount);
        assertEq(usdc.balanceOf(feeRecipient), feeRecipientBalanceBefore + protocolFee);
        assertEq(usdc.balanceOf(integrator), integratorBalanceBefore + integratorFeeAmount);
        assertEq(usdc.balanceOf(seller), sellerBalanceBefore + (quotedAmount - protocolFee - integratorFeeAmount));
        assertEq(usdc.balanceOf(address(feeStore)), 0);
    }

    /// @dev Scans recorded logs for the zero-protocol-fee path: asserts no ProtocolFeePaid was
    ///      emitted and no settlement-token leg paid the protocol recipient. Returns the number
    ///      of settlement-token Transfer events seen.
    function _assertNoProtocolFeeLeg(address protocolRecipient) internal view returns (uint256 settlementTransfers) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 protocolFeeTopic = keccak256("ProtocolFeePaid(uint256,uint256,address,uint256)");
        bytes32 transferTopic = keccak256("Transfer(address,address,uint256)");

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length == 0) continue;
            assertTrue(logs[i].topics[0] != protocolFeeTopic);
            if (logs[i].emitter == address(usdc) && logs[i].topics[0] == transferTopic) {
                settlementTransfers++;
                assertTrue(address(uint160(uint256(logs[i].topics[2]))) != protocolRecipient);
            }
        }
    }

    function test_PurchaseSignedReceipt_ZeroProtocolFeeSkipsTransferAndEvent() public {
        NotaReceiptStore zeroFeeStore = _deployStore(0);
        uint256 listingId = _createListingAs(zeroFeeStore, seller, listingHash);
        uint256 integratorFeeAmount = quotedAmount * 200 / 10_000;
        uint256 sellerBalanceBefore = usdc.balanceOf(seller);
        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);

        assertEq(zeroFeeStore.PROTOCOL_FEE_BPS(), 0);

        {
            NotaReceiptStore.SignedReceiptQuote memory quote = _makeSignedReceiptQuoteWithIntegrator(
                listingId,
                buyer,
                purchaseRef,
                quotedAmount,
                INTEGRATOR,
                integratorFeeAmount,
                uint64(block.timestamp + 1 days)
            );
            bytes memory signature = _signSignedReceiptQuote(zeroFeeStore, SELLER_PK, quote);

            vm.startPrank(buyer);
            usdc.approve(address(zeroFeeStore), quotedAmount);
            vm.recordLogs();
            zeroFeeStore.purchaseSignedReceipt(quote, signature, address(0));
            vm.stopPrank();
        }

        // buyer -> store, store -> integrator, store -> seller. No fourth leg for the protocol.
        assertEq(_assertNoProtocolFeeLeg(feeRecipient), 3);

        // sellerNet == gross - integratorFee, with nothing withheld for the protocol.
        assertEq(usdc.balanceOf(feeRecipient), feeRecipientBalanceBefore);
        assertEq(usdc.balanceOf(INTEGRATOR), integratorFeeAmount);
        assertEq(usdc.balanceOf(seller), sellerBalanceBefore + (quotedAmount - integratorFeeAmount));
        assertEq(usdc.balanceOf(address(zeroFeeStore)), 0);
    }

    function test_PurchaseSignedReceipt_MaxProtocolAndMaxIntegratorFeeSettles() public {
        NotaReceiptStore maxFeeStore = _deployStore(uint16(store.MAX_PROTOCOL_FEE_BPS()));
        uint256 listingId = _createListingAs(maxFeeStore, seller, listingHash);
        address integrator = address(0x1A7E);
        uint256 integratorFeeAmount = quotedAmount * maxFeeStore.MAX_INTEGRATOR_FEE_BPS() / 10_000;
        uint256 protocolFee = quotedAmount * maxFeeStore.MAX_PROTOCOL_FEE_BPS() / 10_000;
        NotaReceiptStore.SignedReceiptQuote memory quote = _makeSignedReceiptQuoteWithIntegrator(
            listingId,
            buyer,
            purchaseRef,
            quotedAmount,
            integrator,
            integratorFeeAmount,
            uint64(block.timestamp + 1 days)
        );
        bytes memory signature = _signSignedReceiptQuote(maxFeeStore, SELLER_PK, quote);
        uint256 sellerBalanceBefore = usdc.balanceOf(seller);
        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);
        uint256 integratorBalanceBefore = usdc.balanceOf(integrator);

        uint256 receiptId = _purchaseSignedReceiptAs(maxFeeStore, buyer, quote, signature);

        assertEq(receiptId, 1);
        assertEq(usdc.balanceOf(feeRecipient), feeRecipientBalanceBefore + protocolFee);
        assertEq(usdc.balanceOf(integrator), integratorBalanceBefore + integratorFeeAmount);
        assertEq(usdc.balanceOf(seller), sellerBalanceBefore + quotedAmount - protocolFee - integratorFeeAmount);
        assertEq(usdc.balanceOf(address(maxFeeStore)), 0);
    }

    function test_PurchaseSignedReceipt_QuoteAmountOverridesListingUnitPrice() public {
        NotaReceiptStore feeStore = _deployStore(50);
        uint256 listingId = _createListingAs(feeStore, seller, listingHash);
        NotaReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 days));
        bytes memory signature = _signSignedReceiptQuote(feeStore, SELLER_PK, quote);
        uint256 protocolFee = quotedAmount * 50 / 10_000;

        _purchaseSignedReceiptAs(feeStore, buyer, quote, signature);

        NotaReceiptStore.Listing memory listing = feeStore.getListing(listingId);
        EmittedReceipt memory receipt = _lastEmittedReceipt();
        assertEq(listing.unitPrice, unitPrice);
        assertEq(receipt.amount, quotedAmount);
        assertEq(usdc.balanceOf(feeRecipient), protocolFee);
    }

    function test_PurchaseSignedReceipt_UnauthorizedSignerFails() public {
        uint256 listingId = _createListingAsSeller();
        NotaReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 days));
        bytes memory signature = _signSignedReceiptQuote(store, ATTACKER_PK, quote);

        vm.startPrank(buyer);
        usdc.approve(address(store), quotedAmount);
        vm.expectRevert(NotaReceiptStore.InvalidQuoteSigner.selector);
        store.purchaseSignedReceipt(quote, signature, address(0));
        vm.stopPrank();
    }

    function test_PurchaseSignedReceipt_RevokedSignerQuoteFails() public {
        uint256 listingId = _createListingAsSeller();
        _setListingQuoteSigner(store, seller, listingId, quoteSigner, true);

        NotaReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 days));
        bytes memory signature = _signSignedReceiptQuote(store, QUOTE_SIGNER_PK, quote);

        _setListingQuoteSigner(store, seller, listingId, quoteSigner, false);

        vm.startPrank(buyer);
        usdc.approve(address(store), quotedAmount);
        vm.expectRevert(NotaReceiptStore.InvalidQuoteSigner.selector);
        store.purchaseSignedReceipt(quote, signature, address(0));
        vm.stopPrank();
    }

    function test_PurchaseSignedReceipt_AuthorizationCheckedAtPurchaseTime() public {
        NotaReceiptStore feeStore = _deployStore(50);
        uint256 listingId = _createListingAs(feeStore, seller, listingHash);
        _setListingQuoteSigner(feeStore, seller, listingId, quoteSigner, true);

        NotaReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 days));
        bytes memory signature = _signSignedReceiptQuote(feeStore, QUOTE_SIGNER_PK, quote);

        _setListingQuoteSigner(feeStore, seller, listingId, quoteSigner, false);

        vm.startPrank(buyer);
        usdc.approve(address(feeStore), quotedAmount);
        vm.expectRevert(NotaReceiptStore.InvalidQuoteSigner.selector);
        feeStore.purchaseSignedReceipt(quote, signature, address(0));
        vm.stopPrank();
    }

    function test_PurchaseSignedReceipt_WrongBuyerReverts() public {
        uint256 listingId = _createListingAsSeller();
        NotaReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 days));
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        vm.startPrank(attacker);
        usdc.approve(address(store), quotedAmount);
        vm.expectRevert(NotaReceiptStore.QuoteBuyerMismatch.selector);
        store.purchaseSignedReceipt(quote, signature, address(0));
        vm.stopPrank();
    }

    function test_PurchaseSignedReceipt_ZeroBuyerAllowsAnyCaller() public {
        uint256 listingId = _createListingAsSeller();
        // A zero `buyer` leaves the quote unbound: any wallet may submit and pay.
        NotaReceiptStore.SignedReceiptQuote memory quote = _makeSignedReceiptQuote(
            listingId, address(0), purchaseRef, quotedAmount, uint64(block.timestamp + 1 hours)
        );
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        uint256 receiptId = _purchaseSignedReceiptAs(store, attacker, quote, signature);

        assertEq(receiptId, 1);
        EmittedReceipt memory receipt = _lastEmittedReceipt();
        // The payer becomes the recorded buyer even though the quote pre-bound no one.
        assertEq(receipt.buyer, attacker);
        assertEq(receipt.purchaseRef, purchaseRef);
        _assertRegistryConsumption(purchaseRef, address(store));
    }

    function test_PurchaseSignedReceipt_InternalPayerCanDifferFromReceiptBuyer() public {
        NotaReceiptStoreHarness harnessStore = _deployHarnessStore(0);
        uint256 listingId = _createListingAs(harnessStore, seller, listingHash);
        NotaReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 days));
        bytes memory signature = _signSignedReceiptQuote(harnessStore, SELLER_PK, quote);
        address gatewayAdapter = address(0xADA702);
        usdc.mint(gatewayAdapter, quotedAmount);
        uint256 sellerBalanceBefore = usdc.balanceOf(seller);
        uint256 buyerBalanceBefore = usdc.balanceOf(buyer);
        uint256 gatewayAdapterBalanceBefore = usdc.balanceOf(gatewayAdapter);

        vm.prank(gatewayAdapter);
        usdc.approve(address(harnessStore), quotedAmount);

        vm.prank(gatewayAdapter);
        uint256 receiptId =
            harnessStore.purchaseSignedReceiptForPayerAndExpectedBuyer(quote, signature, gatewayAdapter, buyer);

        EmittedReceipt memory receipt = _lastEmittedReceipt();

        assertEq(receiptId, 1);
        assertEq(receipt.buyer, buyer);
        assertEq(receipt.seller, seller);
        assertEq(receipt.amount, quotedAmount);
        assertEq(receipt.purchaseRef, purchaseRef);
        _assertRegistryConsumption(purchaseRef, address(harnessStore));
        assertEq(usdc.balanceOf(gatewayAdapter), gatewayAdapterBalanceBefore - quotedAmount);
        assertEq(usdc.balanceOf(buyer), buyerBalanceBefore);
        assertEq(usdc.balanceOf(seller), sellerBalanceBefore + quotedAmount);
        assertEq(usdc.balanceOf(address(harnessStore)), 0);
    }

    function test_PurchaseSignedReceipt_InternalPayerCanDifferFromReceiptBuyerWithIntegratorFee() public {
        NotaReceiptStoreHarness harnessStore = _deployHarnessStore(50);
        uint256 listingId = _createListingAs(harnessStore, seller, listingHash);
        address gatewayAdapter = address(0xADA702);
        address integrator = address(0x1A7E);
        uint256 integratorFeeAmount = quotedAmount * 200 / 10_000;

        NotaReceiptStore.SignedReceiptQuote memory quote = _makeSignedReceiptQuoteWithIntegrator(
            listingId,
            buyer,
            purchaseRef,
            quotedAmount,
            integrator,
            integratorFeeAmount,
            uint64(block.timestamp + 1 days)
        );

        bytes memory signature = _signSignedReceiptQuote(harnessStore, SELLER_PK, quote);

        usdc.mint(gatewayAdapter, quotedAmount);

        vm.prank(gatewayAdapter);
        usdc.approve(address(harnessStore), quotedAmount);

        vm.prank(gatewayAdapter);
        uint256 receiptId =
            harnessStore.purchaseSignedReceiptForPayerAndExpectedBuyer(quote, signature, gatewayAdapter, buyer);

        EmittedReceipt memory receipt = _lastEmittedReceipt();

        assertEq(receiptId, 1);
        assertEq(receipt.buyer, buyer);
        assertEq(receipt.seller, seller);
        assertEq(receipt.amount, quotedAmount);
        assertEq(receipt.purchaseRef, purchaseRef);
        assertEq(usdc.balanceOf(gatewayAdapter), 0);
        assertEq(usdc.balanceOf(buyer), 10_000_000_000);
        assertEq(usdc.balanceOf(feeRecipient), quotedAmount * 50 / 10_000);
        assertEq(usdc.balanceOf(integrator), integratorFeeAmount);
        assertEq(usdc.balanceOf(seller), quotedAmount - (quotedAmount * 50 / 10_000) - integratorFeeAmount);
        assertEq(usdc.balanceOf(address(harnessStore)), 0);
    }

    function test_PurchaseSignedReceipt_ExpiredQuoteReverts() public {
        vm.warp(3 hours);
        uint256 listingId = _createListingAsSeller();
        NotaReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp - 1));
        quote.issuedAt = uint64(block.timestamp - 2 hours);
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        vm.startPrank(buyer);
        usdc.approve(address(store), quotedAmount);
        vm.expectRevert(NotaReceiptStore.QuoteExpired.selector);
        store.purchaseSignedReceipt(quote, signature, address(0));
        vm.stopPrank();
    }

    function test_PurchaseSignedReceipt_QuoteExpiringExactlyNowReverts() public {
        vm.warp(3 hours);
        uint256 listingId = _createListingAsSeller();
        NotaReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, 0);
        quote.issuedAt = uint64(block.timestamp - 1 hours);
        quote.expiresAt = uint64(block.timestamp);
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        vm.startPrank(buyer);
        usdc.approve(address(store), quotedAmount);
        vm.expectRevert(NotaReceiptStore.QuoteExpired.selector);
        store.purchaseSignedReceipt(quote, signature, address(0));
        vm.stopPrank();
    }

    function test_PurchaseSignedReceipt_QuoteExpiringInFutureSucceeds() public {
        NotaReceiptStore feeStore = _deployStore(50);
        uint256 listingId = _createListingAs(feeStore, seller, listingHash);
        NotaReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, 0);
        quote.issuedAt = uint64(block.timestamp);
        quote.expiresAt = uint64(block.timestamp + 1 hours);
        bytes memory signature = _signSignedReceiptQuote(feeStore, SELLER_PK, quote);
        uint256 sellerBalanceBefore = usdc.balanceOf(seller);
        uint256 buyerBalanceBefore = usdc.balanceOf(buyer);
        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);
        uint256 protocolFee = quotedAmount * 50 / 10_000;

        vm.startPrank(buyer);
        usdc.approve(address(feeStore), quotedAmount);

        vm.expectEmit(true, true, true, true);
        emit NotaReceiptStore.ProtocolFeePaid(1, listingId, feeRecipient, protocolFee);
        vm.expectEmit(true, true, true, true);
        emit NotaReceiptStore.SellerPaid(1, listingId, seller, quotedAmount - protocolFee);
        vm.expectEmit(true, true, true, true);
        emit NotaReceiptStore.ReceiptPurchasedV2(
            1, seller, buyer, listingId, purchaseRef, quotedAmount, metadataHash, bytes32(0)
        );

        uint256 receiptId = feeStore.purchaseSignedReceipt(quote, signature, address(0));
        vm.stopPrank();

        EmittedReceipt memory receipt = _lastEmittedReceipt();
        assertEq(receiptId, 1);
        assertEq(receipt.amount, quotedAmount);
        assertEq(usdc.balanceOf(buyer), buyerBalanceBefore - quotedAmount);
        assertEq(usdc.balanceOf(seller), sellerBalanceBefore + (quotedAmount - protocolFee));
        assertEq(usdc.balanceOf(feeRecipient), feeRecipientBalanceBefore + protocolFee);
    }

    function test_PurchaseSignedReceipt_QuoteExpiryBeyondMaxTtlReverts() public {
        uint256 listingId = _createListingAsSeller();
        NotaReceiptStore.SignedReceiptQuote memory quote = _makeSignedReceiptQuote(
            listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + store.MAX_QUOTE_TTL() + 1)
        );
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        vm.startPrank(buyer);
        usdc.approve(address(store), quotedAmount);
        vm.expectRevert(NotaReceiptStore.QuoteExpiryTooLong.selector);
        store.purchaseSignedReceipt(quote, signature, address(0));
        vm.stopPrank();
    }

    function test_PurchaseSignedReceipt_LongLivedQuoteCannotBecomeValidLater() public {
        uint64 day1 = 1_700_000_000;
        vm.warp(day1);

        uint256 listingId = _createListingAsSeller();
        NotaReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(day1 + 7 days));
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        vm.warp(day1 + 6 days);
        vm.startPrank(buyer);
        usdc.approve(address(store), quotedAmount);
        vm.expectRevert(NotaReceiptStore.QuoteExpiryTooLong.selector);
        store.purchaseSignedReceipt(quote, signature, address(0));
        vm.stopPrank();
    }

    function test_PurchaseSignedReceipt_QuoteExpiryAtMaxTtlSucceeds() public {
        uint256 listingId = _createListingAsSeller();
        NotaReceiptStore.SignedReceiptQuote memory quote = _makeSignedReceiptQuote(
            listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + store.MAX_QUOTE_TTL())
        );
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        uint256 receiptId = _purchaseSignedReceiptAs(store, buyer, quote, signature);
        assertEq(receiptId, 1);
    }

    function test_PurchaseSignedReceipt_ExpiresAtOneSecondAfterIssuedAtSucceeds() public {
        uint256 listingId = _createListingAsSeller();
        NotaReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1));
        quote.issuedAt = uint64(block.timestamp);
        quote.expiresAt = uint64(block.timestamp + 1);
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        uint256 receiptId = _purchaseSignedReceiptAs(store, buyer, quote, signature);
        assertEq(receiptId, 1);
    }

    function test_PurchaseSignedReceipt_FutureIssuedAtReverts() public {
        uint256 listingId = _createListingAsSeller();
        NotaReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 hours));
        quote.issuedAt = uint64(block.timestamp + 1);
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        vm.startPrank(buyer);
        usdc.approve(address(store), quotedAmount);
        vm.expectRevert(NotaReceiptStore.InvalidParams.selector);
        store.purchaseSignedReceipt(quote, signature, address(0));
        vm.stopPrank();
    }

    function test_PurchaseSignedReceipt_ExpiresAtEqualToIssuedAtReverts() public {
        uint256 listingId = _createListingAsSeller();
        NotaReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 hours));
        quote.issuedAt = uint64(block.timestamp);
        quote.expiresAt = quote.issuedAt;
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        vm.startPrank(buyer);
        usdc.approve(address(store), quotedAmount);
        vm.expectRevert(NotaReceiptStore.InvalidParams.selector);
        store.purchaseSignedReceipt(quote, signature, address(0));
        vm.stopPrank();
    }

    function test_PurchaseSignedReceipt_QuoteAmountBelowMinReverts() public {
        uint256 listingId = _createListingAsSeller();
        NotaReceiptStore.SignedReceiptQuote memory quote = _makeSignedReceiptQuote(
            listingId, buyer, purchaseRef, store.MIN_PURCHASE_AMOUNT() - 1, uint64(block.timestamp + 1 days)
        );
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        vm.startPrank(buyer);
        usdc.approve(address(store), quote.amount);
        vm.expectRevert(NotaReceiptStore.AmountOutOfBounds.selector);
        store.purchaseSignedReceipt(quote, signature, address(0));
        vm.stopPrank();
    }

    function test_PurchaseSignedReceipt_QuoteAmountAtMinSucceeds() public {
        uint256 listingId = _createListingAsSeller();
        NotaReceiptStore.SignedReceiptQuote memory quote = _makeSignedReceiptQuote(
            listingId, buyer, purchaseRef, store.MIN_PURCHASE_AMOUNT(), uint64(block.timestamp + 1 days)
        );
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        _purchaseSignedReceiptAs(store, buyer, quote, signature);
        assertEq(_lastEmittedReceipt().amount, store.MIN_PURCHASE_AMOUNT());
    }

    /// @dev The floor is 1e2 so x402 agent payments (fractions of a cent) can settle. At that
    ///      size a 50 bps protocol fee floor-divides to zero -- it needs grossAmount >= 200 to
    ///      reach a single base unit -- so the seller nets the entire gross.
    function test_PurchaseSignedReceipt_AtFloorRoundsProtocolFeeToZero() public {
        NotaReceiptStore feeStore = _deployStore(50);
        uint256 listingId = _createListingAs(feeStore, seller, listingHash);
        uint256 floorAmount = feeStore.MIN_PURCHASE_AMOUNT();
        assertEq(floorAmount, 1e2);

        NotaReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, floorAmount, uint64(block.timestamp + 1 days));

        (, uint256 protocolFee, uint256 integratorFee, uint256 sellerNet,,,,) =
            feeStore.previewSignedReceiptPurchase(quote);

        assertEq(protocolFee, 0);
        assertEq(integratorFee, 0);
        assertEq(sellerNet, floorAmount);

        uint256 sellerBalanceBefore = usdc.balanceOf(seller);
        bytes memory signature = _signSignedReceiptQuote(feeStore, SELLER_PK, quote);
        _purchaseSignedReceiptAs(feeStore, buyer, quote, signature);
        assertEq(usdc.balanceOf(seller), sellerBalanceBefore + floorAmount);
    }

    /// @dev Worst case at the floor: max protocol fee and the largest integrator fee the cap
    ///      allows. The seller still nets 96 of 100, so a zero payout is not reachable.
    function test_PurchaseSignedReceipt_AtFloorWithMaxIntegratorFeeStillPaysSeller() public {
        NotaReceiptStore feeStore = _deployStore(50);
        uint256 listingId = _createListingAs(feeStore, seller, listingHash);
        uint256 floorAmount = feeStore.MIN_PURCHASE_AMOUNT();
        uint256 maxIntegratorFee = floorAmount * feeStore.MAX_INTEGRATOR_FEE_BPS() / 10_000;
        assertEq(maxIntegratorFee, 4);

        NotaReceiptStore.SignedReceiptQuote memory quote = _makeSignedReceiptQuoteWithIntegrator(
            listingId, buyer, purchaseRef, floorAmount, INTEGRATOR, maxIntegratorFee, uint64(block.timestamp + 1 days)
        );

        (, uint256 protocolFee, uint256 integratorFee, uint256 sellerNet,,,,) =
            feeStore.previewSignedReceiptPurchase(quote);

        assertEq(protocolFee, 0);
        assertEq(integratorFee, 4);
        assertEq(sellerNet, 96);
    }

    /// @dev The invariants the lowered floor has to hold across the whole amount range: fees can
    ///      never reach the gross, sellerNet is never zero, and nothing is lost or created in the
    ///      split. Runs against a 50 bps store, the worst case for the seller.
    function testFuzz_PreviewSignedReceiptPurchase_FeesNeverReachGross(uint256 rawAmount, uint256 rawIntegratorFee)
        public
    {
        NotaReceiptStore feeStore = _deployStore(50);
        uint256 listingId = _createListingAs(feeStore, seller, listingHash);

        uint256 amount = bound(rawAmount, feeStore.MIN_PURCHASE_AMOUNT(), 1e15);
        uint256 maxIntegratorFee = amount * feeStore.MAX_INTEGRATOR_FEE_BPS() / 10_000;
        uint256 integratorFeeAmount = bound(rawIntegratorFee, 0, maxIntegratorFee);
        address integratorRecipient = integratorFeeAmount == 0 ? address(0) : INTEGRATOR;

        NotaReceiptStore.SignedReceiptQuote memory quote = _makeSignedReceiptQuoteWithIntegrator(
            listingId,
            buyer,
            purchaseRef,
            amount,
            integratorRecipient,
            integratorFeeAmount,
            uint64(block.timestamp + 1 days)
        );

        (, uint256 protocolFee, uint256 integratorFee, uint256 sellerNet,,,,) =
            feeStore.previewSignedReceiptPurchase(quote);

        // Both fees floor-divide and the caps sum to 500 bps, so the rake is at most 5%.
        assertLe(protocolFee + integratorFee, amount / 20);
        assertLt(protocolFee + integratorFee, amount);
        assertGt(sellerNet, 0);
        assertEq(protocolFee + integratorFee + sellerNet, amount);
    }

    // -------------------------------------------------------------------------
    // ERC-1271 contract-wallet sellers
    // -------------------------------------------------------------------------

    function _createWalletListing(MockSmartWallet wallet) internal returns (uint256 listingId) {
        vm.prank(address(wallet));
        listingId = store.createListing(listingHash, unitPrice, NotaReceiptStore.ListingMode.PublicFixedPrice);
    }

    /// @dev The reason for SignatureChecker: a Coinbase Smart Wallet seller is a contract account
    ///      with no key to recover, so ECDSA.recover could never authenticate one.
    function test_PurchaseSignedReceipt_ContractWalletSellerCanSignQuote() public {
        MockSmartWallet wallet = new MockSmartWallet(vm.addr(SELLER2_PK));
        uint256 listingId = _createWalletListing(wallet);

        NotaReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 days));
        bytes memory signature = _signSignedReceiptQuote(store, SELLER2_PK, quote);

        uint256 walletBalanceBefore = usdc.balanceOf(address(wallet));
        uint256 receiptId = _purchaseSignedReceiptAs(store, buyer, quote, signature);

        assertEq(receiptId, 1);
        assertEq(_lastEmittedReceipt().seller, address(wallet));
        assertEq(usdc.balanceOf(address(wallet)), walletBalanceBefore + quotedAmount);
    }

    /// @dev The quote-lifetime consequence of ERC-1271: contract signatures are revocable, so a
    ///      seller rotating wallet owners invalidates every quote that wallet already signed, even
    ///      unexpired ones. ECDSA signatures never behave this way. Outstanding payment links
    ///      break at rotation, which integrators have to plan for.
    function test_PurchaseSignedReceipt_ContractWalletOwnerRotationInvalidatesUnexpiredQuote() public {
        MockSmartWallet wallet = new MockSmartWallet(vm.addr(SELLER2_PK));
        uint256 listingId = _createWalletListing(wallet);

        NotaReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 days));
        bytes memory signature = _signSignedReceiptQuote(store, SELLER2_PK, quote);

        // Still well inside the quote's validity window.
        wallet.rotateOwner(vm.addr(ATTACKER_PK));
        vm.warp(block.timestamp + 1 hours);

        vm.startPrank(buyer);
        usdc.approve(address(store), quotedAmount);
        vm.expectRevert(NotaReceiptStore.InvalidQuoteSigner.selector);
        store.purchaseSignedReceipt(quote, signature, address(0));
        vm.stopPrank();

        _assertRegistryNotConsumed(purchaseRef);
    }

    /// @dev A wallet that rejects or reverts must fail the purchase cleanly rather than trapping
    ///      the transaction: SignatureChecker returns false instead of bubbling.
    function test_PurchaseSignedReceipt_RejectingContractWalletRevertsInvalidQuoteSigner() public {
        RejectingSmartWallet wallet = new RejectingSmartWallet();
        vm.prank(address(wallet));
        uint256 listingId = store.createListing(listingHash, unitPrice, NotaReceiptStore.ListingMode.PublicFixedPrice);

        NotaReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 days));
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        vm.startPrank(buyer);
        usdc.approve(address(store), quotedAmount);
        vm.expectRevert(NotaReceiptStore.InvalidQuoteSigner.selector);
        store.purchaseSignedReceipt(quote, signature, address(0));
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // claimedSigner
    // -------------------------------------------------------------------------

    /// @dev Asserting a signer proves nothing. An address that is not authorized for the listing
    ///      fails the mapping lookup no matter who submits the call.
    function test_PurchaseSignedReceipt_ClaimedSignerNotAuthorizedReverts() public {
        uint256 listingId = _createListingAsSeller();
        NotaReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 days));
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        vm.startPrank(buyer);
        usdc.approve(address(store), quotedAmount);
        vm.expectRevert(NotaReceiptStore.InvalidQuoteSigner.selector);
        store.purchaseSignedReceipt(quote, signature, attacker);
        vm.stopPrank();
    }

    /// @dev Naming an authorized signer does not let a different signer's signature through.
    ///      Authorization and verification are both required.
    function test_PurchaseSignedReceipt_ClaimedSignerAuthorizedButWrongSignatureReverts() public {
        uint256 listingId = _createListingAsSeller();
        _setListingQuoteSigner(store, seller, listingId, quoteSigner, true);

        NotaReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 days));
        // Signed by the seller, but the caller claims the authorized delegate produced it.
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        vm.startPrank(buyer);
        usdc.approve(address(store), quotedAmount);
        vm.expectRevert(NotaReceiptStore.InvalidQuoteSigner.selector);
        store.purchaseSignedReceipt(quote, signature, quoteSigner);
        vm.stopPrank();
    }

    /// @dev Naming the seller explicitly is equivalent to passing zero, which matters because a
    ///      seller can never appear in their own authorizedQuoteSigners mapping.
    function test_PurchaseSignedReceipt_ClaimedSignerMayNameTheSellerExplicitly() public {
        uint256 listingId = _createListingAsSeller();
        NotaReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 days));
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        assertFalse(store.authorizedQuoteSigners(listingId, seller));
        uint256 receiptId = _purchaseSignedReceiptAs(store, buyer, quote, signature, seller);
        assertEq(receiptId, 1);
    }

    // -------------------------------------------------------------------------
    // agentId
    // -------------------------------------------------------------------------

    function test_PurchaseSignedReceipt_AgentIdRoundTripsThroughTheEvent() public {
        bytes32 agentId = keccak256("erc8004:agent:42");
        uint256 listingId = _createListingAsSeller();
        NotaReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 days));
        quote.agentId = agentId;
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        _purchaseSignedReceiptAs(store, buyer, quote, signature);

        assertEq(_lastEmittedReceipt().agentId, agentId);
    }

    /// @dev agentId is inside the signed payload, so a buyer cannot attach an agent identity the
    ///      seller did not attest to. That is what makes the attestation worth anything.
    function test_PurchaseSignedReceipt_TamperedAgentIdInvalidatesSignature() public {
        uint256 listingId = _createListingAsSeller();
        NotaReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 days));
        quote.agentId = keccak256("erc8004:agent:42");
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        quote.agentId = keccak256("erc8004:agent:999");

        vm.startPrank(buyer);
        usdc.approve(address(store), quotedAmount);
        vm.expectRevert(NotaReceiptStore.InvalidQuoteSigner.selector);
        store.purchaseSignedReceipt(quote, signature, address(0));
        vm.stopPrank();
    }

    /// @dev Zero means unspecified and must stay valid: most purchases carry no agent, and the
    ///      direct path cannot express one at all.
    function test_PurchaseReceipt_DirectPathEmitsZeroAgentId() public {
        uint256 listingId = _createListingAsSeller();
        _purchaseReceiptAs(listingId, buyer, purchaseRef);

        assertEq(_lastEmittedReceipt().agentId, bytes32(0));
    }

    function test_PurchaseSignedReceipt_LargeQuoteAmountSucceeds() public {
        uint256 listingId = _createListingAsSeller();
        NotaReceiptStore.SignedReceiptQuote memory quote = _makeSignedReceiptQuote(
            listingId, buyer, purchaseRef, largePurchaseAmount, uint64(block.timestamp + 1 days)
        );
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        _purchaseSignedReceiptAs(store, buyer, quote, signature);
        assertEq(_lastEmittedReceipt().amount, largePurchaseAmount);
    }

    function test_PurchaseSignedReceipt_IntegratorRecipientWithoutFeeReverts() public {
        uint256 listingId = _createListingAsSeller();
        NotaReceiptStore.SignedReceiptQuote memory quote = _makeSignedReceiptQuoteWithIntegrator(
            listingId, buyer, purchaseRef, quotedAmount, address(0x1A7E), 0, uint64(block.timestamp + 1 days)
        );
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        vm.startPrank(buyer);
        usdc.approve(address(store), quotedAmount);
        vm.expectRevert(NotaReceiptStore.InvalidParams.selector);
        store.purchaseSignedReceipt(quote, signature, address(0));
        vm.stopPrank();
    }

    function test_PurchaseSignedReceipt_IntegratorFeeWithoutRecipientReverts() public {
        uint256 listingId = _createListingAsSeller();
        NotaReceiptStore.SignedReceiptQuote memory quote = _makeSignedReceiptQuoteWithIntegrator(
            listingId, buyer, purchaseRef, quotedAmount, address(0), 1, uint64(block.timestamp + 1 days)
        );
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        vm.startPrank(buyer);
        usdc.approve(address(store), quotedAmount);
        vm.expectRevert(NotaReceiptStore.InvalidParams.selector);
        store.purchaseSignedReceipt(quote, signature, address(0));
        vm.stopPrank();
    }

    function test_PurchaseSignedReceipt_IntegratorFeeTooHighReverts() public {
        uint256 listingId = _createListingAsSeller();
        uint256 integratorFeeAmount = quotedAmount * 451 / 10_000;
        NotaReceiptStore.SignedReceiptQuote memory quote = _makeSignedReceiptQuoteWithIntegrator(
            listingId,
            buyer,
            purchaseRef,
            quotedAmount,
            address(0x1A7E),
            integratorFeeAmount,
            uint64(block.timestamp + 1 days)
        );
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        vm.startPrank(buyer);
        usdc.approve(address(store), quotedAmount);
        vm.expectRevert(NotaReceiptStore.IntegratorFeeTooHigh.selector);
        store.purchaseSignedReceipt(quote, signature, address(0));
        vm.stopPrank();
    }

    function test_PurchaseSignedReceipt_ZeroPurchaseRefReverts() public {
        uint256 listingId = _createListingAsSeller();
        NotaReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, bytes32(0), quotedAmount, uint64(block.timestamp + 1 days));
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        vm.startPrank(buyer);
        usdc.approve(address(store), quotedAmount);
        vm.expectRevert(NotaReceiptStore.InvalidPurchaseRef.selector);
        store.purchaseSignedReceipt(quote, signature, address(0));
        vm.stopPrank();
    }

    function test_PurchaseSignedReceipt_ZeroMetadataHashReverts() public {
        uint256 listingId = _createListingAsSeller();
        NotaReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 days));
        quote.metadataHash = bytes32(0);
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        vm.startPrank(buyer);
        usdc.approve(address(store), quotedAmount);
        vm.expectRevert(NotaReceiptStore.InvalidParams.selector);
        store.purchaseSignedReceipt(quote, signature, address(0));
        vm.stopPrank();
    }

    function test_PurchaseSignedReceipt_DuplicatePurchaseRefSameSellerReverts() public {
        uint256 listingId = _createListingAsSeller();
        NotaReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 days));
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        uint256 receiptId = _purchaseSignedReceiptAs(store, buyer, quote, signature);

        vm.startPrank(buyer);
        usdc.approve(address(store), quotedAmount);
        vm.expectRevert(NotaReceiptStore.PurchaseRefAlreadyUsed.selector);
        store.purchaseSignedReceipt(quote, signature, address(0));
        vm.stopPrank();

        assertEq(receiptId, 1);
    }

    function test_PurchaseSignedReceipt_InactiveListingReverts() public {
        uint256 listingId = _createListingAsSeller();
        NotaReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 days));
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        vm.prank(seller);
        store.setListingActive(listingId, false);

        vm.startPrank(buyer);
        usdc.approve(address(store), quotedAmount);
        vm.expectRevert(NotaReceiptStore.ListingInactive.selector);
        store.purchaseSignedReceipt(quote, signature, address(0));
        vm.stopPrank();
    }

    function test_PurchaseSignedReceipt_AuthorizationIsListingScoped() public {
        uint256 listingId = _createListingAs(seller, listingHash);
        uint256 otherListingId = _createListingAs(seller, listingHash2);
        _setListingQuoteSigner(store, seller, listingId, quoteSigner, true);

        NotaReceiptStore.SignedReceiptQuote memory otherListingQuote =
            _makeSignedReceiptQuote(otherListingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 days));
        bytes memory otherListingSignature = _signSignedReceiptQuote(store, QUOTE_SIGNER_PK, otherListingQuote);

        vm.startPrank(buyer);
        usdc.approve(address(store), quotedAmount);
        vm.expectRevert(NotaReceiptStore.InvalidQuoteSigner.selector);
        store.purchaseSignedReceipt(otherListingQuote, otherListingSignature, quoteSigner);
        vm.stopPrank();

        _setListingQuoteSigner(store, seller, otherListingId, quoteSigner, true);
        uint256 otherListingReceiptId =
            _purchaseSignedReceiptAs(store, buyer, otherListingQuote, otherListingSignature, quoteSigner);
        assertEq(otherListingReceiptId, 1);
        _assertRegistryConsumption(purchaseRef, address(store));

        NotaReceiptStore.SignedReceiptQuote memory authorizedListingQuote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef2, quotedAmount, uint64(block.timestamp + 1 days));
        bytes memory authorizedListingSignature =
            _signSignedReceiptQuote(store, QUOTE_SIGNER_PK, authorizedListingQuote);

        uint256 receiptId =
            _purchaseSignedReceiptAs(store, buyer, authorizedListingQuote, authorizedListingSignature, quoteSigner);
        assertEq(receiptId, 2);
        _assertRegistryConsumption(purchaseRef2, address(store));
    }

    function test_PurchaseSignedReceipt_ListingSignerDoesNotWorkForDifferentSellerListing() public {
        uint256 sellerListingId = _createListingAs(seller, listingHash);
        uint256 seller2ListingId = _createListingAs(store, seller2, listingHash2);
        _setListingQuoteSigner(store, seller, sellerListingId, quoteSigner, true);

        NotaReceiptStore.SignedReceiptQuote memory seller2Quote = _makeSignedReceiptQuote(
            seller2ListingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 days)
        );
        bytes memory signature = _signSignedReceiptQuote(store, QUOTE_SIGNER_PK, seller2Quote);

        vm.startPrank(buyer);
        usdc.approve(address(store), quotedAmount);
        vm.expectRevert(NotaReceiptStore.InvalidQuoteSigner.selector);
        store.purchaseSignedReceipt(seller2Quote, signature, address(0));
        vm.stopPrank();
    }

    function test_PurchaseSignedReceipt_PurchaseRefReplayAcrossDifferentSellersReverts() public {
        uint256 listingId1 = _createListingAs(seller, listingHash);
        uint256 listingId2 = _createListingAs(store, seller2, listingHash2);
        NotaReceiptStore.SignedReceiptQuote memory quote1 =
            _makeSignedReceiptQuote(listingId1, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 days));
        NotaReceiptStore.SignedReceiptQuote memory quote2 =
            _makeSignedReceiptQuote(listingId2, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 days));
        bytes memory signature1 = _signSignedReceiptQuote(store, SELLER_PK, quote1);
        bytes memory signature2 = _signSignedReceiptQuote(store, SELLER2_PK, quote2);

        uint256 receiptId1 = _purchaseSignedReceiptAs(store, buyer, quote1, signature1);

        assertEq(receiptId1, 1);
        _assertRegistryConsumption(purchaseRef, address(store));

        vm.startPrank(buyer);
        usdc.approve(address(store), quotedAmount);
        vm.expectRevert(NotaReceiptStore.PurchaseRefAlreadyUsed.selector);
        store.purchaseSignedReceipt(quote2, signature2, address(0));
        vm.stopPrank();
    }

    function test_PurchaseSignedReceipt_SharedRegistryBlocksReplayAcrossStores() public {
        NotaReceiptStore secondStore = _deployStore(0, address(this), registry);
        uint256 listingId1 = _createListingAs(store, seller, listingHash);
        uint256 listingId2 = _createListingAs(secondStore, seller2, listingHash2);
        NotaReceiptStore.SignedReceiptQuote memory quote1 =
            _makeSignedReceiptQuote(listingId1, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 days));
        NotaReceiptStore.SignedReceiptQuote memory quote2 =
            _makeSignedReceiptQuote(listingId2, buyer2, purchaseRef, quotedAmount, uint64(block.timestamp + 1 days));
        bytes memory signature1 = _signSignedReceiptQuote(store, SELLER_PK, quote1);
        bytes memory signature2 = _signSignedReceiptQuote(secondStore, SELLER2_PK, quote2);

        uint256 receiptId = _purchaseSignedReceiptAs(store, buyer, quote1, signature1);

        assertEq(receiptId, 1);
        assertEq(registry.consumedBy(purchaseRef), address(store));

        vm.startPrank(buyer2);
        usdc.approve(address(secondStore), quotedAmount);
        vm.expectRevert(NotaReceiptStore.PurchaseRefAlreadyUsed.selector);
        secondStore.purchaseSignedReceipt(quote2, signature2, address(0));
        vm.stopPrank();
    }

    function test_PurchaseSignedReceipt_SignatureFromStoreCannotBeUsedOnSecondStore() public {
        NotaReceiptStore secondStore = _deployStore(0, address(this), registry);
        uint256 listingId1 = _createListingAs(store, seller, listingHash);
        uint256 listingId2 = _createListingAs(secondStore, seller, listingHash);
        NotaReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId1, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 days));
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        vm.startPrank(buyer);
        usdc.approve(address(secondStore), quotedAmount);
        vm.expectRevert(NotaReceiptStore.InvalidQuoteSigner.selector);
        secondStore.purchaseSignedReceipt(
            NotaReceiptStore.SignedReceiptQuote({
                listingId: listingId2,
                buyer: quote.buyer,
                purchaseRef: quote.purchaseRef,
                amount: quote.amount,
                metadataHash: quote.metadataHash,
                agentId: quote.agentId,
                integratorFeeRecipient: quote.integratorFeeRecipient,
                integratorFeeAmount: quote.integratorFeeAmount,
                issuedAt: quote.issuedAt,
                expiresAt: quote.expiresAt
            }),
            signature,
            address(0)
        );
        vm.stopPrank();
    }

    function test_PurchaseSignedReceipt_FailedTransferDoesNotConsumeRegistry() public {
        uint256 listingId = _createListingAsSeller();
        NotaReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 days));
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        vm.prank(buyer);
        vm.expectRevert();
        store.purchaseSignedReceipt(quote, signature, address(0));

        _assertRegistryNotConsumed(purchaseRef);
    }

    function test_HashSignedReceiptQuote_MatchesTestGeneratedEIP712Digest() public {
        uint256 listingId = _createListingAsSeller();
        NotaReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 days));

        bytes32 digest = store.hashSignedReceiptQuote(quote);
        bytes32 expectedDigest = _expectedSignedReceiptQuoteDigest(store, quote);
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);
        address recoveredSigner = ECDSA.recover(digest, signature);

        assertEq(digest, expectedDigest);
        assertEq(recoveredSigner, seller);
    }

    function test_HashSignedReceiptQuote_DependsOnPurchaseRefRegistry() public {
        PurchaseRefRegistry secondRegistry = new PurchaseRefRegistry(address(this));
        NotaReceiptStore secondStoreWithDifferentRegistry = _deployStore(0, address(this), secondRegistry);
        uint256 listingId1 = _createListingAs(store, seller, listingHash);
        uint256 listingId2 = _createListingAs(secondStoreWithDifferentRegistry, seller, listingHash);
        NotaReceiptStore.SignedReceiptQuote memory quote1 =
            _makeSignedReceiptQuote(listingId1, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 days));
        NotaReceiptStore.SignedReceiptQuote memory quote2 =
            _makeSignedReceiptQuote(listingId2, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 days));

        bytes32 structHash1 = _expectedSignedReceiptQuoteStructHash(store, quote1);
        bytes32 structHash2 = _expectedSignedReceiptQuoteStructHash(secondStoreWithDifferentRegistry, quote2);

        assertNotEq(structHash1, structHash2);
        assertNotEq(
            store.hashSignedReceiptQuote(quote1), secondStoreWithDifferentRegistry.hashSignedReceiptQuote(quote2)
        );
    }

    function test_HashPurchaseRef_MatchesCanonicalEncoding() public {
        uint256 listingId = _createListingAsSeller();
        string memory rawPurchaseRef = _makeRawPurchaseRef(1);

        bytes32 purchaseRefHash = store.hashPurchaseRef(seller, listingId, rawPurchaseRef, purchaseRefNonce);
        bytes32 expectedHash = _expectedPurchaseRefHash(seller, rawPurchaseRef, purchaseRefNonce);

        assertEq(purchaseRefHash, expectedHash);
    }

    function test_HashPurchaseRef_DoesNotDependOnReceiptStoreAddress() public {
        NotaReceiptStore secondStore = _deployStore(0, address(this), registry);
        string memory rawPurchaseRef = _makeRawPurchaseRef(5);

        uint256 firstListingId = _createListingAs(store, seller, listingHash);
        uint256 secondListingId = _createListingAs(secondStore, seller, listingHash);

        bytes32 firstHash = store.hashPurchaseRef(seller, firstListingId, rawPurchaseRef, purchaseRefNonce);
        bytes32 secondHash = secondStore.hashPurchaseRef(seller, secondListingId, rawPurchaseRef, purchaseRefNonce);

        assertEq(firstListingId, secondListingId);
        assertEq(firstHash, secondHash);
    }

    function test_PurchaseReceipt_SharedRegistryBlocksReplayAcrossStores() public {
        NotaReceiptStore secondStore = _deployStore(0, address(this), registry);
        uint256 firstListingId = _createListingAs(store, seller, listingHash);
        uint256 secondListingId = _createListingAs(secondStore, seller2, listingHash2);

        uint256 receiptId = _purchaseReceiptAs(store, firstListingId, buyer, purchaseRef);

        assertEq(receiptId, 1);
        _assertRegistryConsumption(purchaseRef, address(store));

        vm.startPrank(buyer2);
        usdc.approve(address(secondStore), unitPrice);
        vm.expectRevert(NotaReceiptStore.PurchaseRefAlreadyUsed.selector);
        secondStore.purchaseReceipt(secondListingId, purchaseRef, unitPrice);
        vm.stopPrank();
    }

    function test_HashPurchaseRef_SameInputsReturnSameHash() public {
        uint256 listingId = _createListingAsSeller();
        string memory rawPurchaseRef = _makeRawPurchaseRef(2);

        bytes32 firstHash = store.hashPurchaseRef(seller, listingId, rawPurchaseRef, purchaseRefNonce);
        bytes32 secondHash = store.hashPurchaseRef(seller, listingId, rawPurchaseRef, purchaseRefNonce);

        assertEq(firstHash, secondHash);
    }

    function test_HashPurchaseRef_DifferentRawPurchaseRefReturnsDifferentHash() public {
        uint256 listingId = _createListingAsSeller();
        string memory firstRawPurchaseRef = _makeRawPurchaseRef(8);
        string memory secondRawPurchaseRef = _makeRawPurchaseRef(9);

        bytes32 firstHash = store.hashPurchaseRef(seller, listingId, firstRawPurchaseRef, purchaseRefNonce);
        bytes32 secondHash = store.hashPurchaseRef(seller, listingId, secondRawPurchaseRef, purchaseRefNonce);

        assertNotEq(firstHash, secondHash);
    }

    function test_HashPurchaseRef_DifferentNonceReturnsDifferentHash() public {
        uint256 listingId = _createListingAsSeller();
        string memory rawPurchaseRef = _makeRawPurchaseRef(12);

        // Same business reference, different secret nonce -> different on-chain commitment.
        bytes32 firstHash = store.hashPurchaseRef(seller, listingId, rawPurchaseRef, purchaseRefNonce);
        bytes32 secondHash = store.hashPurchaseRef(seller, listingId, rawPurchaseRef, purchaseRefNonce2);

        assertNotEq(firstHash, secondHash);
    }

    function test_HashPurchaseRef_ZeroNonceDiffersFromNonZeroNonce() public {
        uint256 listingId = _createListingAsSeller();
        string memory rawPurchaseRef = _makeRawPurchaseRef(13);

        bytes32 zeroNonceHash = store.hashPurchaseRef(seller, listingId, rawPurchaseRef, bytes32(0));
        bytes32 nonZeroNonceHash = store.hashPurchaseRef(seller, listingId, rawPurchaseRef, purchaseRefNonce);

        assertNotEq(zeroNonceHash, nonZeroNonceHash);
    }

    function test_HashPurchaseRef_DoesNotDependOnListingId() public {
        uint256 listingId1 = _createListingAs(seller, listingHash);
        uint256 listingId2 = _createListingAs(seller, listingHash2);
        string memory rawPurchaseRef = _makeRawPurchaseRef(3);

        bytes32 firstHash = store.hashPurchaseRef(seller, listingId1, rawPurchaseRef, purchaseRefNonce);
        bytes32 secondHash = store.hashPurchaseRef(seller, listingId2, rawPurchaseRef, purchaseRefNonce);

        assertEq(firstHash, secondHash);
    }

    function test_HashPurchaseRef_DifferentSettlementTokenReturnsDifferentHash() public {
        ReceiptMockUSDC secondUsdc = new ReceiptMockUSDC();
        NotaReceiptStore secondStore =
            new NotaReceiptStore(address(secondUsdc), address(registry), feeRecipient, 0, address(this));
        uint256 listingId1 = _createListingAs(store, seller, listingHash);
        uint256 listingId2 = _createListingAs(secondStore, seller, listingHash);
        string memory rawPurchaseRef = _makeRawPurchaseRef(10);

        bytes32 firstHash = store.hashPurchaseRef(seller, listingId1, rawPurchaseRef, purchaseRefNonce);
        bytes32 secondHash = secondStore.hashPurchaseRef(seller, listingId2, rawPurchaseRef, purchaseRefNonce);

        assertNotEq(firstHash, secondHash);
    }

    function test_HashPurchaseRef_DifferentSellerReturnsDifferentHash() public {
        uint256 listingId1 = _createListingAs(seller, listingHash);
        uint256 listingId2 = _createListingAs(seller2, listingHash2);
        string memory rawPurchaseRef = _makeRawPurchaseRef(4);

        bytes32 firstHash = store.hashPurchaseRef(seller, listingId1, rawPurchaseRef, purchaseRefNonce);
        bytes32 secondHash = store.hashPurchaseRef(seller2, listingId2, rawPurchaseRef, purchaseRefNonce);

        assertNotEq(firstHash, secondHash);
    }

    function test_HashPurchaseRef_ListingIdOnlyValidatesOwnership() public {
        uint256 sellerListingId = _createListingAs(seller, listingHash);
        uint256 seller2ListingId = _createListingAs(seller2, listingHash2);
        string memory rawPurchaseRef = _makeRawPurchaseRef(11);

        bytes32 hash = store.hashPurchaseRef(seller, sellerListingId, rawPurchaseRef, purchaseRefNonce);
        assertEq(hash, _expectedPurchaseRefHash(seller, rawPurchaseRef, purchaseRefNonce));

        vm.expectRevert(NotaReceiptStore.InvalidParams.selector);
        store.hashPurchaseRef(seller, seller2ListingId, rawPurchaseRef, purchaseRefNonce);
    }

    function test_HashPurchaseRef_EmptyRawPurchaseRefReverts() public {
        uint256 listingId = _createListingAsSeller();

        vm.expectRevert(NotaReceiptStore.InvalidPurchaseRef.selector);
        store.hashPurchaseRef(seller, listingId, "", purchaseRefNonce);
    }

    function test_HashPurchaseRef_RawPurchaseRefTooLongReverts() public {
        uint256 listingId = _createListingAsSeller();
        string memory rawPurchaseRef = _makeStringOfLength(129);

        vm.expectRevert(NotaReceiptStore.InvalidPurchaseRef.selector);
        store.hashPurchaseRef(seller, listingId, rawPurchaseRef, purchaseRefNonce);
    }

    function test_PurchaseSignedReceipt_MetadataHashMismatchInvalidatesSignature() public {
        uint256 listingId = _createListingAsSeller();
        NotaReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 days));
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        quote.metadataHash = metadataHash2;

        vm.startPrank(buyer);
        usdc.approve(address(store), quotedAmount);
        vm.expectRevert(NotaReceiptStore.InvalidQuoteSigner.selector);
        store.purchaseSignedReceipt(quote, signature, address(0));
        vm.stopPrank();
    }

    function test_ValidateSignedReceiptPurchase_ReturnsExpectedValues() public {
        NotaReceiptStore feeStore = _deployStore(50);
        uint256 listingId = _createListingAs(feeStore, seller, listingHash);
        _setListingQuoteSigner(feeStore, seller, listingId, quoteSigner, true);
        address integrator = address(0x1A7E);
        uint256 integratorFeeAmount = quotedAmount * 200 / 10_000;
        uint256 protocolFeeAmount = quotedAmount * 50 / 10_000;
        NotaReceiptStore.SignedReceiptQuote memory quote = _makeSignedReceiptQuoteWithIntegrator(
            listingId,
            buyer,
            purchaseRef,
            quotedAmount,
            integrator,
            integratorFeeAmount,
            uint64(block.timestamp + 1 hours)
        );
        bytes memory signature = _signSignedReceiptQuote(feeStore, QUOTE_SIGNER_PK, quote);

        NotaReceiptStore.SignedReceiptPurchaseValidation memory validation =
            feeStore.validateSignedReceiptPurchase(quote, signature, buyer, quoteSigner);

        assertEq(validation.grossAmount, quotedAmount);
        assertEq(validation.protocolFee, protocolFeeAmount);
        assertEq(validation.integratorFee, integratorFeeAmount);
        assertEq(validation.sellerNet, quotedAmount - protocolFeeAmount - integratorFeeAmount);
        assertEq(validation.protocolFeeRecipient, feeRecipient);
        assertEq(validation.integratorFeeRecipient, integrator);
        assertEq(validation.seller, seller);
        assertEq(validation.listingHash, listingHash);
        assertEq(validation.verifiedSigner, quoteSigner);
    }

    function test_ValidateSignedReceiptPurchase_InvalidSignatureReverts() public {
        uint256 listingId = _createListingAsSeller();
        NotaReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 hours));
        bytes memory signature = _signSignedReceiptQuote(store, ATTACKER_PK, quote);

        vm.expectRevert(NotaReceiptStore.InvalidQuoteSigner.selector);
        store.validateSignedReceiptPurchase(quote, signature, buyer, address(0));
    }

    function test_ValidateSignedReceiptPurchase_WrongExpectedBuyerReverts() public {
        uint256 listingId = _createListingAsSeller();
        NotaReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 hours));
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        vm.expectRevert(NotaReceiptStore.QuoteBuyerMismatch.selector);
        store.validateSignedReceiptPurchase(quote, signature, attacker, address(0));
    }

    function test_ValidateSignedReceiptPurchase_ZeroBuyerPassesForAnyExpectedBuyer() public {
        uint256 listingId = _createListingAsSeller();
        // Unbound quote (zero buyer) validates for an arbitrary expectedBuyer, mirroring the
        // purchase path where any wallet may pay.
        NotaReceiptStore.SignedReceiptQuote memory quote = _makeSignedReceiptQuote(
            listingId, address(0), purchaseRef, quotedAmount, uint64(block.timestamp + 1 hours)
        );
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        NotaReceiptStore.SignedReceiptPurchaseValidation memory validation =
            store.validateSignedReceiptPurchase(quote, signature, attacker, address(0));

        assertEq(validation.grossAmount, quotedAmount);
        assertEq(validation.seller, seller);
        assertEq(validation.verifiedSigner, seller);
    }

    function test_ValidateSignedReceiptPurchase_ExpiredQuoteReverts() public {
        vm.warp(3 hours);
        uint256 listingId = _createListingAsSeller();
        NotaReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp - 1));
        quote.issuedAt = uint64(block.timestamp - 2 hours);
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        vm.expectRevert(NotaReceiptStore.QuoteExpired.selector);
        store.validateSignedReceiptPurchase(quote, signature, buyer, address(0));
    }

    function test_ValidateSignedReceiptPurchase_ExpiresAtEqualToIssuedAtReverts() public {
        uint256 listingId = _createListingAsSeller();
        NotaReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 hours));
        quote.issuedAt = uint64(block.timestamp);
        quote.expiresAt = quote.issuedAt;
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        vm.expectRevert(NotaReceiptStore.InvalidParams.selector);
        store.validateSignedReceiptPurchase(quote, signature, buyer, address(0));
    }

    function test_ValidateSignedReceiptPurchase_QuoteExpiryTooLongReverts() public {
        uint256 listingId = _createListingAsSeller();
        NotaReceiptStore.SignedReceiptQuote memory quote = _makeSignedReceiptQuote(
            listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + store.MAX_QUOTE_TTL() + 1)
        );
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        vm.expectRevert(NotaReceiptStore.QuoteExpiryTooLong.selector);
        store.validateSignedReceiptPurchase(quote, signature, buyer, address(0));
    }

    function test_ValidateSignedReceiptPurchase_InactiveListingReverts() public {
        uint256 listingId = _createListingAsSeller();
        NotaReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 hours));
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        vm.prank(seller);
        store.setListingActive(listingId, false);

        vm.expectRevert(NotaReceiptStore.ListingInactive.selector);
        store.validateSignedReceiptPurchase(quote, signature, buyer, address(0));
    }

    function test_ValidateSignedReceiptPurchase_ZeroPurchaseRefReverts() public {
        uint256 listingId = _createListingAsSeller();
        NotaReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, bytes32(0), quotedAmount, uint64(block.timestamp + 1 hours));
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        vm.expectRevert(NotaReceiptStore.InvalidPurchaseRef.selector);
        store.validateSignedReceiptPurchase(quote, signature, buyer, address(0));
    }

    function test_ValidateSignedReceiptPurchase_RefConsumedByAnotherConsumerReverts() public {
        uint256 listingId = _createListingAsSeller();
        NotaReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 hours));
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);
        address externalConsumer = address(0xBAD);
        _authorizeRegistryConsumer(registry, externalConsumer);

        vm.prank(externalConsumer);
        registry.consume(purchaseRef);

        assertEq(registry.consumedBy(purchaseRef), externalConsumer);

        vm.expectRevert(NotaReceiptStore.PurchaseRefAlreadyUsed.selector);
        store.validateSignedReceiptPurchase(quote, signature, buyer, address(0));
    }

    function test_ValidateSignedReceiptPurchase_UsedPurchaseRefReverts() public {
        uint256 listingId = _createListingAsSeller();
        NotaReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 hours));
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        uint256 receiptId = _purchaseSignedReceiptAs(store, buyer, quote, signature);

        vm.expectRevert(NotaReceiptStore.PurchaseRefAlreadyUsed.selector);
        store.validateSignedReceiptPurchase(quote, signature, buyer, address(0));
        assertEq(receiptId, 1);
        _assertRegistryConsumption(purchaseRef, address(store));
    }

    function test_PreviewSignedReceiptPurchase_ReturnsExpectedValues() public {
        NotaReceiptStore feeStore = _deployStore(50);
        uint256 listingId = _createListingAs(feeStore, seller, listingHash);
        NotaReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 days));

        (
            uint256 grossAmount,
            uint256 protocolFee,
            uint256 integratorFee,
            uint256 sellerNet,
            address quotedFeeRecipient,
            address quotedIntegratorFeeRecipient,
            address quotedSeller,
            bytes32 quotedListingHash
        ) = feeStore.previewSignedReceiptPurchase(quote);

        assertEq(grossAmount, quotedAmount);
        assertEq(protocolFee, quotedAmount * 50 / 10_000);
        assertEq(integratorFee, 0);
        assertEq(sellerNet, quotedAmount - protocolFee);
        assertEq(quotedFeeRecipient, feeRecipient);
        assertEq(quotedIntegratorFeeRecipient, address(0));
        assertEq(quotedSeller, seller);
        assertEq(quotedListingHash, listingHash);
    }

    function test_PreviewSignedReceiptPurchase_WithIntegratorFeeReturnsExpectedValues() public {
        NotaReceiptStore feeStore = _deployStore(50);
        uint256 listingId = _createListingAs(feeStore, seller, listingHash);
        address integrator = address(0x1A7E);
        uint256 integratorFeeAmount = quotedAmount * 200 / 10_000;
        NotaReceiptStore.SignedReceiptQuote memory quote = _makeSignedReceiptQuoteWithIntegrator(
            listingId,
            buyer,
            purchaseRef,
            quotedAmount,
            integrator,
            integratorFeeAmount,
            uint64(block.timestamp + 1 days)
        );

        (
            uint256 grossAmount,
            uint256 protocolFee,
            uint256 integratorFee,
            uint256 sellerNet,
            address quotedFeeRecipient,
            address quotedIntegratorFeeRecipient,
            address quotedSeller,
            bytes32 quotedListingHash
        ) = feeStore.previewSignedReceiptPurchase(quote);

        assertEq(grossAmount, quotedAmount);
        assertEq(protocolFee, quotedAmount * 50 / 10_000);
        assertEq(integratorFee, integratorFeeAmount);
        assertEq(sellerNet, quotedAmount - protocolFee - integratorFeeAmount);
        assertEq(quotedFeeRecipient, feeRecipient);
        assertEq(quotedIntegratorFeeRecipient, integrator);
        assertEq(quotedSeller, seller);
        assertEq(quotedListingHash, listingHash);
    }

    function test_PreviewSignedReceiptPurchase_ZeroProtocolFeeWithIntegratorFeeReturnsExpectedValues() public {
        uint256 listingId = _createListingAsSeller();
        address integrator = address(0x1A7E);
        uint256 integratorFeeAmount = quotedAmount * 200 / 10_000;
        NotaReceiptStore.SignedReceiptQuote memory quote = _makeSignedReceiptQuoteWithIntegrator(
            listingId,
            buyer,
            purchaseRef,
            quotedAmount,
            integrator,
            integratorFeeAmount,
            uint64(block.timestamp + 1 days)
        );

        (
            uint256 grossAmount,
            uint256 protocolFee,
            uint256 integratorFee,
            uint256 sellerNet,
            address quotedFeeRecipient,
            address quotedIntegratorFeeRecipient,
            address quotedSeller,
            bytes32 quotedListingHash
        ) = store.previewSignedReceiptPurchase(quote);

        assertEq(grossAmount, quotedAmount);
        assertEq(protocolFee, 0);
        assertEq(integratorFee, integratorFeeAmount);
        assertEq(sellerNet, quotedAmount - integratorFeeAmount);
        assertEq(quotedFeeRecipient, feeRecipient);
        assertEq(quotedIntegratorFeeRecipient, integrator);
        assertEq(quotedSeller, seller);
        assertEq(quotedListingHash, listingHash);
    }

    function test_PreviewSignedReceiptPurchase_MaxProtocolAndMaxIntegratorFeeReturnsExpectedValues() public {
        NotaReceiptStore maxFeeStore = _deployStore(uint16(store.MAX_PROTOCOL_FEE_BPS()));
        uint256 listingId = _createListingAs(maxFeeStore, seller, listingHash);
        address integrator = address(0x1A7E);
        uint256 integratorFeeAmount = quotedAmount * maxFeeStore.MAX_INTEGRATOR_FEE_BPS() / 10_000;
        uint256 protocolFee = quotedAmount * maxFeeStore.MAX_PROTOCOL_FEE_BPS() / 10_000;
        NotaReceiptStore.SignedReceiptQuote memory quote = _makeSignedReceiptQuoteWithIntegrator(
            listingId,
            buyer,
            purchaseRef,
            quotedAmount,
            integrator,
            integratorFeeAmount,
            uint64(block.timestamp + 1 days)
        );

        (
            uint256 grossAmount,
            uint256 quotedProtocolFee,
            uint256 quotedIntegratorFee,
            uint256 sellerNet,
            address quotedFeeRecipient,
            address quotedIntegratorFeeRecipient,
            address quotedSeller,
            bytes32 quotedListingHash
        ) = maxFeeStore.previewSignedReceiptPurchase(quote);

        assertEq(grossAmount, quotedAmount);
        assertEq(quotedProtocolFee, protocolFee);
        assertEq(quotedIntegratorFee, integratorFeeAmount);
        assertEq(sellerNet, quotedAmount - protocolFee - integratorFeeAmount);
        assertEq(quotedFeeRecipient, feeRecipient);
        assertEq(quotedIntegratorFeeRecipient, integrator);
        assertEq(quotedSeller, seller);
        assertEq(quotedListingHash, listingHash);
    }

    function test_PreviewSignedReceiptPurchase_ZeroAmountReverts() public {
        uint256 listingId = _createListingAsSeller();
        NotaReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, 0, uint64(block.timestamp + 1 days));

        vm.expectRevert(NotaReceiptStore.AmountOutOfBounds.selector);
        store.previewSignedReceiptPurchase(quote);
    }

    function test_PreviewSignedReceiptPurchase_ZeroPurchaseRefReverts() public {
        uint256 listingId = _createListingAsSeller();
        NotaReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, bytes32(0), quotedAmount, uint64(block.timestamp + 1 days));

        vm.expectRevert(NotaReceiptStore.InvalidPurchaseRef.selector);
        store.previewSignedReceiptPurchase(quote);
    }

    function test_PreviewSignedReceiptPurchase_ZeroMetadataHashReverts() public {
        uint256 listingId = _createListingAsSeller();
        NotaReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 days));
        quote.metadataHash = bytes32(0);

        vm.expectRevert(NotaReceiptStore.InvalidParams.selector);
        store.previewSignedReceiptPurchase(quote);
    }

    function test_PreviewSignedReceiptPurchase_IntegratorRecipientWithoutFeeReverts() public {
        uint256 listingId = _createListingAsSeller();
        NotaReceiptStore.SignedReceiptQuote memory quote = _makeSignedReceiptQuoteWithIntegrator(
            listingId, buyer, purchaseRef, quotedAmount, address(0x1A7E), 0, uint64(block.timestamp + 1 days)
        );

        vm.expectRevert(NotaReceiptStore.InvalidParams.selector);
        store.previewSignedReceiptPurchase(quote);
    }

    function test_PreviewSignedReceiptPurchase_IntegratorFeeWithoutRecipientReverts() public {
        uint256 listingId = _createListingAsSeller();
        NotaReceiptStore.SignedReceiptQuote memory quote = _makeSignedReceiptQuoteWithIntegrator(
            listingId, buyer, purchaseRef, quotedAmount, address(0), 1, uint64(block.timestamp + 1 days)
        );

        vm.expectRevert(NotaReceiptStore.InvalidParams.selector);
        store.previewSignedReceiptPurchase(quote);
    }

    function test_PreviewSignedReceiptPurchase_IntegratorFeeTooHighReverts() public {
        uint256 listingId = _createListingAsSeller();
        uint256 integratorFeeAmount = quotedAmount * 451 / 10_000;
        NotaReceiptStore.SignedReceiptQuote memory quote = _makeSignedReceiptQuoteWithIntegrator(
            listingId,
            buyer,
            purchaseRef,
            quotedAmount,
            address(0x1A7E),
            integratorFeeAmount,
            uint64(block.timestamp + 1 days)
        );

        vm.expectRevert(NotaReceiptStore.IntegratorFeeTooHigh.selector);
        store.previewSignedReceiptPurchase(quote);
    }

    function test_QuotePurchaseReceipt_ReturnsGrossFeeAndNet() public {
        NotaReceiptStore feeStore = _deployStore(50);
        uint256 listingId = _createListingAs(feeStore, seller, listingHash);

        (uint256 grossAmount, uint256 protocolFee, uint256 sellerNet, address quotedFeeRecipient) =
            feeStore.quotePurchaseReceipt(listingId);

        assertEq(grossAmount, unitPrice);
        assertEq(protocolFee, unitPrice * 50 / 10_000);
        assertEq(sellerNet, unitPrice - protocolFee);
        assertEq(quotedFeeRecipient, feeRecipient);
    }

    function test_QuotePurchaseReceipt_ZeroProtocolFeeReturnsGrossAsSellerNet() public {
        uint256 listingId = _createListingAsSeller();

        (uint256 grossAmount, uint256 protocolFee, uint256 sellerNet, address quotedFeeRecipient) =
            store.quotePurchaseReceipt(listingId);

        assertEq(grossAmount, unitPrice);
        assertEq(protocolFee, 0);
        assertEq(sellerNet, unitPrice);
        assertEq(quotedFeeRecipient, feeRecipient);
    }

    function test_GetListing_NotFoundReverts() public {
        vm.expectRevert(NotaReceiptStore.ListingNotFound.selector);
        store.getListing(999);
    }

    /// @dev Receipts are not stored on-chain, so the `ReceiptPurchasedV2` event must carry every
    ///      field an indexer needs. `issuedAt` is deliberately absent: it was always
    ///      `block.timestamp`, which the log's own block supplies.
    function test_ReceiptPurchasedV2_EventCarriesEveryReceiptField() public {
        uint256 listingId = _createListingAsSeller();
        uint256 receiptId = _purchaseReceiptAs(listingId, buyer, purchaseRef);

        EmittedReceipt memory receipt = _lastEmittedReceipt();
        assertEq(receipt.receiptId, receiptId);
        assertEq(receipt.listingId, listingId);
        assertEq(receipt.seller, seller);
        assertEq(receipt.buyer, buyer);
        assertEq(receipt.purchaseRef, purchaseRef);
        assertEq(receipt.amount, unitPrice);
        assertEq(receipt.metadataHash, bytes32(0));
    }

    /// @dev Receipt ids stay monotonic even though nothing is written per receipt.
    function test_NextReceiptId_IncrementsWithoutReceiptStorage() public {
        uint256 listingId = _createListingAsSeller();

        assertEq(store.nextReceiptId(), 1);
        assertEq(_purchaseReceiptAs(listingId, buyer, purchaseRef), 1);
        assertEq(store.nextReceiptId(), 2);
        assertEq(_purchaseReceiptAs(listingId, buyer, purchaseRef2), 2);
        assertEq(store.nextReceiptId(), 3);
    }

    /// @dev The topic layout is permanent once indexers point at it. `purchaseRef` must stay
    ///      indexed: it is what an integrator filters `eth_getLogs` on to resolve a purchase
    ///      reference to its settlement, which is the lookup the removed seller-scoped mapping
    ///      used to serve.
    function test_ReceiptPurchasedV2_EventIndexesSellerBuyerAndPurchaseRef() public {
        uint256 listingId = _createListingAsSeller();

        vm.recordLogs();
        uint256 receiptId = _purchaseReceiptAs(listingId, buyer, purchaseRef);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        bytes32 receiptPurchasedTopic0 =
            keccak256("ReceiptPurchasedV2(uint256,address,address,uint256,bytes32,uint256,bytes32,bytes32)");
        bool found;

        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].topics.length == 4 && entries[i].topics[0] == receiptPurchasedTopic0) {
                found = true;
                assertEq(entries[i].topics[1], bytes32(uint256(uint160(seller))));
                assertEq(entries[i].topics[2], bytes32(uint256(uint160(buyer))));
                assertEq(entries[i].topics[3], purchaseRef);

                (uint256 loggedReceiptId, uint256 loggedListingId, uint256 loggedAmount, bytes32 loggedMetadataHash) =
                    abi.decode(entries[i].data, (uint256, uint256, uint256, bytes32));

                assertEq(loggedReceiptId, receiptId);
                assertEq(loggedListingId, listingId);
                assertEq(loggedAmount, unitPrice);
                assertEq(loggedMetadataHash, bytes32(0));
                break;
            }
        }

        assertTrue(found);
    }
}
