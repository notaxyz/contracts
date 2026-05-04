// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {PurchaseRefRegistry} from "../src/PurchaseRefRegistry.sol";
import {RevealReceiptStore} from "../src/RevealReceiptStore.sol";

contract ReceiptMockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract RevealReceiptStoreHarness is RevealReceiptStore {
    constructor(
        address settlementToken_,
        address purchaseRefRegistry_,
        address feeRecipient_,
        uint16 protocolFeeBps_,
        address owner_
    ) RevealReceiptStore(settlementToken_, purchaseRefRegistry_, feeRecipient_, protocolFeeBps_, owner_) {}

    function purchaseSignedReceiptForPayerAndExpectedBuyer(
        SignedReceiptQuote calldata quote,
        bytes calldata sellerSignature,
        address payer,
        address expectedBuyer
    ) external nonReentrant listingExists(quote.listingId) returns (uint256 receiptId) {
        if (purchasesPaused) revert PurchasesPaused();
        Listing storage listing = _verifySignedReceiptQuote(quote, sellerSignature, expectedBuyer);

        return _settleVerifiedSignedReceiptQuote(listing, quote, payer, expectedBuyer);
    }

    function _settleVerifiedSignedReceiptQuote(
        Listing storage listing,
        SignedReceiptQuote calldata quote,
        address payer,
        address expectedBuyer
    ) internal returns (uint256 receiptId) {
        return _settleReceiptPurchase(
            quote.listingId,
            listing.seller,
            payer,
            expectedBuyer,
            quote.amount,
            quote.purchaseRef,
            quote.metadataHash,
            quote.integratorFeeRecipient,
            quote.integratorFeeAmount
        );
    }
}

contract RevealReceiptStoreTest is Test {
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    uint256 internal constant SELLER_PK = 0xA11CE;
    uint256 internal constant SELLER2_PK = 0xABCD;
    uint256 internal constant QUOTE_SIGNER_PK = 0xBEEF;
    uint256 internal constant ATTACKER_PK = 0xD00D;

    ReceiptMockUSDC usdc;
    PurchaseRefRegistry registry;
    RevealReceiptStore store;

    address seller;
    address seller2;
    address quoteSigner;
    address buyer = address(0xB0B);
    address buyer2 = address(0xCAFE);
    address attacker;
    address feeRecipient = address(0xFEE);

    bytes32 listingHash = keccak256("listing-1");
    bytes32 listingHash2 = keccak256("listing-2");
    bytes32 metadataHash = keccak256("metadata-1");
    bytes32 metadataHash2 = keccak256("metadata-2");
    uint256 unitPrice = 100_000_000;
    uint256 updatedUnitPrice = 125_000_000;
    uint256 quotedAmount = 250_000_000;
    bytes32 purchaseRef = keccak256("purchase-1");
    bytes32 purchaseRef2 = keccak256("purchase-2");

    function setUp() public {
        usdc = new ReceiptMockUSDC();
        registry = new PurchaseRefRegistry();
        seller = vm.addr(SELLER_PK);
        seller2 = vm.addr(SELLER2_PK);
        quoteSigner = vm.addr(QUOTE_SIGNER_PK);
        attacker = vm.addr(ATTACKER_PK);
        store = new RevealReceiptStore(address(usdc), address(registry), feeRecipient, 0, address(this));

        usdc.mint(buyer, 10_000_000_000);
        usdc.mint(buyer2, 10_000_000_000);
        usdc.mint(attacker, 10_000_000_000);

        vm.deal(seller, 10 ether);
        vm.deal(seller2, 10 ether);
        vm.deal(buyer, 10 ether);
        vm.deal(buyer2, 10 ether);
        vm.deal(attacker, 10 ether);
    }

    function _deployStore(uint16 feeBps) internal returns (RevealReceiptStore deployedStore) {
        deployedStore = _deployStore(feeBps, address(this), registry);
    }

    function _deployStore(uint16 feeBps, address owner_) internal returns (RevealReceiptStore deployedStore) {
        deployedStore = _deployStore(feeBps, owner_, registry);
    }

    function _deployStore(uint16 feeBps, address owner_, PurchaseRefRegistry targetRegistry)
        internal
        returns (RevealReceiptStore deployedStore)
    {
        deployedStore = new RevealReceiptStore(address(usdc), address(targetRegistry), feeRecipient, feeBps, owner_);
    }

    function _deployHarnessStore(uint16 feeBps) internal returns (RevealReceiptStoreHarness deployedStore) {
        deployedStore = _deployHarnessStore(feeBps, address(this), registry);
    }

    function _deployHarnessStore(uint16 feeBps, address owner_)
        internal
        returns (RevealReceiptStoreHarness deployedStore)
    {
        deployedStore = _deployHarnessStore(feeBps, owner_, registry);
    }

    function _deployHarnessStore(uint16 feeBps, address owner_, PurchaseRefRegistry targetRegistry)
        internal
        returns (RevealReceiptStoreHarness deployedStore)
    {
        deployedStore =
            new RevealReceiptStoreHarness(address(usdc), address(targetRegistry), feeRecipient, feeBps, owner_);
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
        RevealReceiptStore targetStore,
        address sellerAccount,
        bytes32 sellerListingHash,
        uint256 price
    ) internal returns (uint256 listingId) {
        vm.prank(sellerAccount);
        listingId = targetStore.createListing(sellerListingHash, price);
    }

    function _createListingAs(RevealReceiptStore targetStore, address sellerAccount, bytes32 sellerListingHash)
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

    function _setQuoteSigner(RevealReceiptStore targetStore, address sellerAccount, address signer, bool authorized)
        internal
    {
        vm.prank(sellerAccount);
        targetStore.setQuoteSigner(signer, authorized);
    }

    function _purchaseReceiptAs(RevealReceiptStore targetStore, uint256 listingId, address who, bytes32 ref)
        internal
        returns (uint256 receiptId)
    {
        RevealReceiptStore.Listing memory listing = targetStore.getListing(listingId);

        vm.startPrank(who);
        usdc.approve(address(targetStore), listing.unitPrice);
        receiptId = targetStore.purchaseReceipt(listingId, ref);
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
    ) internal view returns (RevealReceiptStore.SignedReceiptQuote memory quote) {
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
    ) internal view returns (RevealReceiptStore.SignedReceiptQuote memory quote) {
        quote = RevealReceiptStore.SignedReceiptQuote({
            listingId: listingId,
            buyer: quoteBuyer,
            purchaseRef: ref,
            amount: amount,
            metadataHash: metadataHash,
            integratorFeeRecipient: integratorFeeRecipient,
            integratorFeeAmount: integratorFeeAmount,
            expiresAt: expiresAt
        });
    }

    function _signSignedReceiptQuote(
        RevealReceiptStore targetStore,
        uint256 signerPk,
        RevealReceiptStore.SignedReceiptQuote memory quote
    ) internal view returns (bytes memory signature) {
        bytes32 digest = targetStore.hashSignedReceiptQuote(quote);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        signature = abi.encodePacked(r, s, v);
    }

    function _purchaseSignedReceiptAs(
        RevealReceiptStore targetStore,
        address who,
        RevealReceiptStore.SignedReceiptQuote memory quote,
        bytes memory sellerSignature
    ) internal returns (uint256 receiptId) {
        vm.startPrank(who);
        usdc.approve(address(targetStore), quote.amount);
        receiptId = targetStore.purchaseSignedReceipt(quote, sellerSignature);
        vm.stopPrank();
    }

    function _expectedSignedReceiptQuoteDigest(
        RevealReceiptStore targetStore,
        RevealReceiptStore.SignedReceiptQuote memory quote
    ) internal view returns (bytes32) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("RevealReceiptStore")),
                keccak256(bytes("1")),
                block.chainid,
                address(targetStore)
            )
        );

        return keccak256(
            abi.encodePacked("\x19\x01", domainSeparator, _expectedSignedReceiptQuoteStructHash(targetStore, quote))
        );
    }

    function _expectedSignedReceiptQuoteStructHash(
        RevealReceiptStore targetStore,
        RevealReceiptStore.SignedReceiptQuote memory quote
    ) internal view returns (bytes32) {
        RevealReceiptStore.Listing memory listing = targetStore.getListing(quote.listingId);

        return keccak256(
            abi.encode(
                targetStore.SIGNED_RECEIPT_QUOTE_TYPEHASH(),
                quote.listingId,
                listing.seller,
                quote.buyer,
                quote.purchaseRef,
                quote.amount,
                quote.metadataHash,
                address(targetStore.settlementToken()),
                address(targetStore.purchaseRefRegistry()),
                quote.integratorFeeRecipient,
                quote.integratorFeeAmount,
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

    function _expectedPurchaseRefHash(address sellerAccount, string memory rawPurchaseRef)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode("zkReveal.purchaseRef.receipt.v1", block.chainid, address(usdc), sellerAccount, rawPurchaseRef)
        );
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
        registry.consume(purchaseRef);

        _assertRegistryConsumption(purchaseRef, address(this));

        vm.expectRevert(
            abi.encodeWithSelector(PurchaseRefRegistry.PurchaseRefAlreadyConsumed.selector, purchaseRef, address(this))
        );
        registry.consume(purchaseRef);
    }

    function test_PurchaseRefRegistry_RejectsZeroPurchaseRef() public {
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

        vm.expectEmit(true, true, false, true);
        emit PurchaseRefRegistry.PurchaseRefConsumed(purchaseRef, buyer, expectedConsumedAt);

        vm.prank(buyer);
        registry.consume(purchaseRef);

        _assertRegistryConsumption(purchaseRef, buyer);
    }

    function test_PurchaseRefRegistry_DifferentCallersCannotConsumeSameRef() public {
        vm.prank(buyer);
        registry.consume(purchaseRef);

        vm.prank(buyer2);
        vm.expectRevert(
            abi.encodeWithSelector(PurchaseRefRegistry.PurchaseRefAlreadyConsumed.selector, purchaseRef, buyer)
        );
        registry.consume(purchaseRef);
    }

    function test_PurchaseRefRegistry_DifferentRefsCanBeConsumedBySameCaller() public {
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

        vm.prank(buyer);
        registry.consume(purchaseRef);

        (, uint64 consumedAt) = registry.consumptions(purchaseRef);
        assertEq(consumedAt, expectedConsumedAt);
    }

    function test_ListingCreated_Emits() public {
        vm.expectEmit(true, true, true, true);
        emit RevealReceiptStore.ListingCreated(1, seller, listingHash, unitPrice);

        vm.prank(seller);
        store.createListing(listingHash, unitPrice);
    }

    function test_CreateListing_SetsFields() public {
        assertEq(store.listingCountBySeller(seller), 0);

        uint256 listingId = _createListingAsSeller();

        RevealReceiptStore.Listing memory listing = store.getListing(listingId);
        assertEq(listing.seller, seller);
        assertEq(listing.listingHash, listingHash);
        assertEq(listing.unitPrice, unitPrice);
        assertEq(listing.active, true);

        (address listingSeller, bytes32 storedListingHash, uint256 listingUnitPrice, bool listingActive) =
            store.listings(listingId);
        assertEq(listingSeller, seller);
        assertEq(storedListingHash, listingHash);
        assertEq(listingUnitPrice, unitPrice);
        assertEq(listingActive, true);
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
        vm.expectRevert(RevealReceiptStore.InvalidParams.selector);
        store.createListing(bytes32(0), unitPrice);
    }

    function test_CreateListing_UnitPriceBelowMinReverts() public {
        uint256 belowMin = store.MIN_PURCHASE_AMOUNT() - 1;

        vm.prank(seller);
        vm.expectRevert(RevealReceiptStore.AmountOutOfBounds.selector);
        store.createListing(listingHash, belowMin);
    }

    function test_CreateListing_UnitPriceAtMinSucceeds() public {
        uint256 listingId = _createListingAsSeller(store.MIN_PURCHASE_AMOUNT());
        assertEq(store.getListing(listingId).unitPrice, store.MIN_PURCHASE_AMOUNT());
    }

    function test_CreateListing_UnitPriceAtMaxSucceeds() public {
        uint256 listingId = _createListingAsSeller(store.MAX_PURCHASE_AMOUNT());
        assertEq(store.getListing(listingId).unitPrice, store.MAX_PURCHASE_AMOUNT());
    }

    function test_CreateListing_UnitPriceAboveMaxReverts() public {
        uint256 aboveMax = store.MAX_PURCHASE_AMOUNT() + 1;

        vm.prank(seller);
        vm.expectRevert(RevealReceiptStore.AmountOutOfBounds.selector);
        store.createListing(listingHash, aboveMax);
    }

    function test_Constructor_SucceedsWithValidOwner() public {
        address configuredOwner = address(0xA11CE123);

        RevealReceiptStore ownedStore =
            new RevealReceiptStore(address(usdc), address(registry), feeRecipient, 0, configuredOwner);

        assertEq(ownedStore.owner(), configuredOwner);
    }

    function test_Constructor_InvalidParamsRevert() public {
        vm.expectRevert(RevealReceiptStore.InvalidParams.selector);
        new RevealReceiptStore(address(0), address(registry), feeRecipient, 0, address(this));

        vm.expectRevert(RevealReceiptStore.InvalidParams.selector);
        new RevealReceiptStore(address(usdc), address(registry), address(0), 1, address(this));

        vm.expectRevert(RevealReceiptStore.InvalidParams.selector);
        new RevealReceiptStore(address(usdc), address(registry), feeRecipient, 1_001, address(this));

        vm.expectRevert(RevealReceiptStore.InvalidParams.selector);
        new RevealReceiptStore(address(usdc), address(0), feeRecipient, 0, address(this));
    }

    function test_Constructor_ZeroOwnerReverts() public {
        vm.expectRevert(RevealReceiptStore.InvalidParams.selector);
        new RevealReceiptStore(address(usdc), address(registry), feeRecipient, 0, address(0));
    }

    function test_Constructor_AllowsZeroFeeRecipientWhenFeeDisabled() public {
        RevealReceiptStore zeroFeeStore =
            new RevealReceiptStore(address(usdc), address(registry), address(0), 0, address(this));

        assertEq(address(zeroFeeStore.settlementToken()), address(usdc));
        assertEq(address(zeroFeeStore.purchaseRefRegistry()), address(registry));
        assertEq(zeroFeeStore.feeRecipient(), address(0));
        assertEq(zeroFeeStore.protocolFeeBps(), 0);
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
        emit RevealReceiptStore.ListingCreationPauseChanged(true);
        store.setListingCreationPaused(true);

        vm.expectEmit(false, false, false, true);
        emit RevealReceiptStore.PurchasesPauseChanged(true);
        store.setPurchasesPaused(true);

        vm.expectEmit(false, false, false, true);
        emit RevealReceiptStore.QuoteSignerUpdatesPauseChanged(true);
        store.setQuoteSignerUpdatesPaused(true);
    }

    function test_EIP712Constants_AreExpected() public view {
        assertEq(store.EIP712_NAME(), "RevealReceiptStore");
        assertEq(store.EIP712_VERSION(), "1");
        assertEq(
            store.SIGNED_RECEIPT_QUOTE_TYPEHASH(),
            keccak256(
                "SignedReceiptQuote(uint256 listingId,address seller,address buyer,bytes32 purchaseRef,uint256 amount,bytes32 metadataHash,address settlementToken,address purchaseRefRegistry,address integratorFeeRecipient,uint256 integratorFeeAmount,uint64 expiresAt)"
            )
        );
    }

    function test_ListingCreationPause_BlocksNewListings() public {
        store.setListingCreationPaused(true);

        vm.prank(seller);
        vm.expectRevert(RevealReceiptStore.ListingCreationPaused.selector);
        store.createListing(listingHash, unitPrice);
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
        vm.expectRevert(RevealReceiptStore.SellerListingLimitReached.selector);
        store.createListing(_makeListingHash(maxListings), unitPrice);

        uint256 seller2ListingId = _createListingAs(seller2, _makeListingHash(maxListings + 1));
        assertEq(seller2ListingId, maxListings + 1);
        assertEq(store.listingCountBySeller(seller), maxListings);
        assertEq(store.listingCountBySeller(seller2), 1);
    }

    function test_SetListingActive_TogglesAndBlocksPurchases() public {
        uint256 listingId = _createListingAsSeller();

        vm.expectEmit(true, true, false, true);
        emit RevealReceiptStore.ListingStatusChanged(listingId, seller, false);

        vm.prank(seller);
        store.setListingActive(listingId, false);

        vm.startPrank(buyer);
        usdc.approve(address(store), unitPrice);
        vm.expectRevert(RevealReceiptStore.ListingInactive.selector);
        store.purchaseReceipt(listingId, purchaseRef);
        vm.stopPrank();

        vm.prank(seller);
        store.setListingActive(listingId, true);

        uint256 receiptId = _purchaseReceiptAs(listingId, buyer, purchaseRef);
        assertEq(receiptId, 1);
    }

    function test_SetListingActive_NonSellerReverts() public {
        uint256 listingId = _createListingAsSeller();

        vm.prank(attacker);
        vm.expectRevert(RevealReceiptStore.NotListingSeller.selector);
        store.setListingActive(listingId, false);
    }

    function test_SetListingPrice_UpdatesPriceAndEmits() public {
        uint256 listingId = _createListingAsSeller();

        vm.expectEmit(true, true, false, true);
        emit RevealReceiptStore.ListingPriceChanged(listingId, seller, unitPrice, updatedUnitPrice);

        vm.prank(seller);
        store.setListingPrice(listingId, updatedUnitPrice);

        RevealReceiptStore.Listing memory listing = store.getListing(listingId);
        assertEq(listing.unitPrice, updatedUnitPrice);
    }

    function test_SetListingPrice_NonSellerReverts() public {
        uint256 listingId = _createListingAsSeller();

        vm.prank(attacker);
        vm.expectRevert(RevealReceiptStore.NotListingSeller.selector);
        store.setListingPrice(listingId, updatedUnitPrice);
    }

    function test_SetListingPrice_BelowMinReverts() public {
        uint256 listingId = _createListingAsSeller();
        uint256 belowMinPurchaseAmount = store.MIN_PURCHASE_AMOUNT() - 1;

        vm.prank(seller);
        vm.expectRevert(RevealReceiptStore.AmountOutOfBounds.selector);
        store.setListingPrice(listingId, belowMinPurchaseAmount);
    }

    function test_SetListingPrice_AtMinSucceeds() public {
        uint256 listingId = _createListingAsSeller();
        uint256 minPurchaseAmount = store.MIN_PURCHASE_AMOUNT();

        vm.prank(seller);
        store.setListingPrice(listingId, minPurchaseAmount);

        assertEq(store.getListing(listingId).unitPrice, minPurchaseAmount);
    }

    function test_SetListingPrice_AtMaxSucceeds() public {
        uint256 listingId = _createListingAsSeller();
        uint256 maxPurchaseAmount = store.MAX_PURCHASE_AMOUNT();

        vm.prank(seller);
        store.setListingPrice(listingId, maxPurchaseAmount);

        assertEq(store.getListing(listingId).unitPrice, maxPurchaseAmount);
    }

    function test_SetListingPrice_AboveMaxReverts() public {
        uint256 listingId = _createListingAsSeller();
        uint256 aboveMax = store.MAX_PURCHASE_AMOUNT() + 1;

        vm.prank(seller);
        vm.expectRevert(RevealReceiptStore.AmountOutOfBounds.selector);
        store.setListingPrice(listingId, aboveMax);
    }

    function test_SetQuoteSigner_AuthorizesSigner() public {
        vm.expectEmit(true, true, false, true);
        emit RevealReceiptStore.QuoteSignerAuthorizationChanged(seller, quoteSigner, true);

        vm.prank(seller);
        store.setQuoteSigner(quoteSigner, true);

        assertEq(store.authorizedQuoteSigners(seller, quoteSigner), true);
        assertEq(store.authorizedQuoteSignerCount(seller), 1);
    }

    function test_SetQuoteSigner_IsScopedToCaller() public {
        vm.prank(seller);
        store.setQuoteSigner(quoteSigner, true);

        assertEq(store.authorizedQuoteSigners(seller, quoteSigner), true);
        assertEq(store.authorizedQuoteSigners(seller2, quoteSigner), false);
    }

    function test_SetQuoteSigner_RevokesSigner() public {
        _setQuoteSigner(store, seller, quoteSigner, true);

        vm.expectEmit(true, true, false, true);
        emit RevealReceiptStore.QuoteSignerAuthorizationChanged(seller, quoteSigner, false);

        vm.prank(seller);
        store.setQuoteSigner(quoteSigner, false);

        assertEq(store.authorizedQuoteSigners(seller, quoteSigner), false);
        assertEq(store.authorizedQuoteSignerCount(seller), 0);
    }

    function test_SetQuoteSigner_ZeroSignerRejected() public {
        vm.prank(seller);
        vm.expectRevert(RevealReceiptStore.InvalidParams.selector);
        store.setQuoteSigner(address(0), true);
    }

    function test_SetQuoteSigner_SelfAuthorizationRejected() public {
        vm.prank(seller);
        vm.expectRevert(RevealReceiptStore.InvalidParams.selector);
        store.setQuoteSigner(seller, true);
    }

    function test_SetQuoteSigner_PauseBlocksUpdatesUntilUnpaused() public {
        store.setQuoteSignerUpdatesPaused(true);

        vm.prank(seller);
        vm.expectRevert(RevealReceiptStore.QuoteSignerUpdatesPaused.selector);
        store.setQuoteSigner(quoteSigner, true);

        store.setQuoteSignerUpdatesPaused(false);

        vm.prank(seller);
        store.setQuoteSigner(quoteSigner, true);

        assertTrue(store.authorizedQuoteSigners(seller, quoteSigner));
        assertEq(store.authorizedQuoteSignerCount(seller), 1);
    }

    function test_SetQuoteSigner_TracksCountAndEnforcesCap() public {
        address signer1 = vm.addr(1001);
        address signer2 = vm.addr(1002);
        address signer3 = vm.addr(1003);
        address signer4 = vm.addr(1004);

        _setQuoteSigner(store, seller, signer1, true);
        _setQuoteSigner(store, seller, signer2, true);
        _setQuoteSigner(store, seller, signer3, true);

        assertEq(store.authorizedQuoteSignerCount(seller), store.MAX_QUOTE_SIGNERS_PER_SELLER());

        vm.prank(seller);
        vm.expectRevert(RevealReceiptStore.QuoteSignerLimitReached.selector);
        store.setQuoteSigner(signer4, true);

        vm.prank(seller);
        store.setQuoteSigner(signer1, true);
        assertEq(store.authorizedQuoteSignerCount(seller), store.MAX_QUOTE_SIGNERS_PER_SELLER());

        vm.prank(seller);
        store.setQuoteSigner(signer1, false);
        assertEq(store.authorizedQuoteSignerCount(seller), store.MAX_QUOTE_SIGNERS_PER_SELLER() - 1);

        vm.prank(seller);
        store.setQuoteSigner(signer1, false);
        assertEq(store.authorizedQuoteSignerCount(seller), store.MAX_QUOTE_SIGNERS_PER_SELLER() - 1);

        vm.prank(seller);
        store.setQuoteSigner(signer4, true);
        assertEq(store.authorizedQuoteSigners(seller, signer4), true);
        assertEq(store.authorizedQuoteSignerCount(seller), store.MAX_QUOTE_SIGNERS_PER_SELLER());

        _setQuoteSigner(store, seller2, signer1, true);
        assertEq(store.authorizedQuoteSignerCount(seller2), 1);
        assertEq(store.authorizedQuoteSignerCount(seller), store.MAX_QUOTE_SIGNERS_PER_SELLER());
    }

    function test_SetQuoteSigner_DirectSellerSignatureStillWorksAtSignerCap() public {
        uint256 listingId = _createListingAsSeller();

        _setQuoteSigner(store, seller, vm.addr(1001), true);
        _setQuoteSigner(store, seller, vm.addr(1002), true);
        _setQuoteSigner(store, seller, vm.addr(1003), true);

        RevealReceiptStore.SignedReceiptQuote memory quote = _makeSignedReceiptQuote(
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
        vm.expectRevert(RevealReceiptStore.PurchasesPaused.selector);
        store.purchaseReceipt(listingId, purchaseRef);
        vm.stopPrank();
    }

    function test_PurchasesPause_BlocksPurchaseSignedReceipt() public {
        uint256 listingId = _createListingAsSeller();
        RevealReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 hours));
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        store.setPurchasesPaused(true);

        vm.startPrank(buyer);
        usdc.approve(address(store), quotedAmount);
        vm.expectRevert(RevealReceiptStore.PurchasesPaused.selector);
        store.purchaseSignedReceipt(quote, signature);
        vm.stopPrank();
    }

    function test_PurchasesPause_AllowsSellerConfigAndGetters() public {
        uint256 listingId = _createListingAsSeller();

        store.setPurchasesPaused(true);

        vm.prank(seller);
        store.setListingPrice(listingId, updatedUnitPrice);

        vm.prank(seller);
        store.setListingActive(listingId, false);

        RevealReceiptStore.Listing memory listing = store.getListing(listingId);

        assertEq(listing.unitPrice, updatedUnitPrice);
        assertFalse(listing.active);
        assertEq(store.listingCountBySeller(seller), 1);
    }

    function test_PurchasesPause_UnpauseRestoresPurchases() public {
        uint256 listingId = _createListingAsSeller();

        store.setPurchasesPaused(true);
        store.setPurchasesPaused(false);

        uint256 fixedReceiptId = _purchaseReceiptAs(listingId, buyer, purchaseRef);
        assertEq(fixedReceiptId, 1);

        RevealReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer2, purchaseRef2, quotedAmount, uint64(block.timestamp + 1 hours));
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        uint256 signedReceiptId = _purchaseSignedReceiptAs(store, buyer2, quote, signature);
        assertEq(signedReceiptId, 2);
    }

    function test_PurchaseReceipt_SettlesImmediatelyAndStoresReceipt() public {
        uint256 listingId = _createListingAsSeller();
        uint256 sellerBalanceBefore = usdc.balanceOf(seller);
        uint256 buyerBalanceBefore = usdc.balanceOf(buyer);
        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);

        assertEq(store.getReceiptIdBySellerAndPurchaseRef(seller, purchaseRef), 0);

        vm.startPrank(buyer);
        usdc.approve(address(store), unitPrice);

        vm.expectEmit(true, true, true, true);
        emit RevealReceiptStore.SellerPaid(1, listingId, seller, unitPrice);
        vm.expectEmit(true, true, true, true);
        emit RevealReceiptStore.ReceiptPurchased(1, seller, buyer, listingId, purchaseRef, unitPrice, bytes32(0));

        uint256 receiptId = store.purchaseReceipt(listingId, purchaseRef);
        vm.stopPrank();

        assertEq(receiptId, 1);

        RevealReceiptStore.Receipt memory receipt = store.getReceipt(receiptId);
        assertEq(receipt.listingId, listingId);
        assertEq(receipt.seller, seller);
        assertEq(receipt.buyer, buyer);
        assertEq(receipt.amount, unitPrice);
        assertEq(receipt.purchaseRef, purchaseRef);
        assertEq(receipt.issuedAt, block.timestamp);
        assertEq(store.getReceiptIdBySellerAndPurchaseRef(seller, purchaseRef), receiptId);
        _assertRegistryConsumption(purchaseRef, address(store));
        assertEq(usdc.balanceOf(buyer), buyerBalanceBefore - unitPrice);
        assertEq(usdc.balanceOf(seller), sellerBalanceBefore + unitPrice);
        assertEq(usdc.balanceOf(feeRecipient), feeRecipientBalanceBefore);
        assertEq(usdc.balanceOf(address(store)), 0);
    }

    function test_PurchaseReceipt_WithCanonicalHashStoresReceiptAndMappings() public {
        uint256 listingId = _createListingAsSeller();
        string memory rawPurchaseRef = _makeRawPurchaseRef(5);
        bytes32 canonicalPurchaseRef = store.hashPurchaseRef(seller, listingId, rawPurchaseRef);

        uint256 receiptId = _purchaseReceiptAs(listingId, buyer, canonicalPurchaseRef);

        RevealReceiptStore.Receipt memory receipt = store.getReceipt(receiptId);
        assertEq(receipt.purchaseRef, canonicalPurchaseRef);
        assertEq(store.getReceiptIdBySellerAndPurchaseRef(seller, canonicalPurchaseRef), receiptId);
        _assertRegistryConsumption(canonicalPurchaseRef, address(store));
    }

    function test_PurchaseReceipt_EmitsPurchaseRefConsumedFromRegistry() public {
        uint256 listingId = _createListingAsSeller();

        vm.startPrank(buyer);
        usdc.approve(address(store), unitPrice);

        vm.expectEmit(true, true, false, true, address(registry));
        emit PurchaseRefRegistry.PurchaseRefConsumed(purchaseRef, address(store), uint64(block.timestamp));

        store.purchaseReceipt(listingId, purchaseRef);
        vm.stopPrank();
    }

    function test_PurchaseReceipt_PaysProtocolFeeAndSellerNet() public {
        RevealReceiptStore feeStore = _deployStore(500);
        uint256 listingId = _createListingAs(feeStore, seller, listingHash);
        address integrator = address(0x1A7E);
        uint256 sellerBalanceBefore = usdc.balanceOf(seller);
        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);
        uint256 integratorBalanceBefore = usdc.balanceOf(integrator);
        uint256 protocolFee = unitPrice * 500 / 10_000;

        vm.startPrank(buyer);
        usdc.approve(address(feeStore), unitPrice);

        vm.expectEmit(true, true, true, true);
        emit RevealReceiptStore.ProtocolFeePaid(1, listingId, feeRecipient, protocolFee);
        vm.expectEmit(true, true, true, true);
        emit RevealReceiptStore.SellerPaid(1, listingId, seller, unitPrice - protocolFee);
        vm.expectEmit(true, true, true, true);
        emit RevealReceiptStore.ReceiptPurchased(1, seller, buyer, listingId, purchaseRef, unitPrice, bytes32(0));

        feeStore.purchaseReceipt(listingId, purchaseRef);
        vm.stopPrank();

        assertEq(usdc.balanceOf(feeRecipient), feeRecipientBalanceBefore + protocolFee);
        assertEq(usdc.balanceOf(integrator), integratorBalanceBefore);
        assertEq(usdc.balanceOf(seller), sellerBalanceBefore + (unitPrice - protocolFee));
        assertEq(usdc.balanceOf(address(feeStore)), 0);
    }

    function test_PurchaseReceipt_ChargesUpdatedPriceAfterPriceUpdate() public {
        uint256 listingId = _createListingAsSeller();
        uint256 sellerBalanceBefore = usdc.balanceOf(seller);
        uint256 buyerBalanceBefore = usdc.balanceOf(buyer);

        vm.prank(seller);
        store.setListingPrice(listingId, updatedUnitPrice);

        vm.startPrank(buyer);
        usdc.approve(address(store), updatedUnitPrice);

        vm.expectEmit(true, true, true, true);
        emit RevealReceiptStore.SellerPaid(1, listingId, seller, updatedUnitPrice);
        vm.expectEmit(true, true, true, true);
        emit RevealReceiptStore.ReceiptPurchased(1, seller, buyer, listingId, purchaseRef, updatedUnitPrice, bytes32(0));

        uint256 receiptId = store.purchaseReceipt(listingId, purchaseRef);
        vm.stopPrank();

        RevealReceiptStore.Receipt memory receipt = store.getReceipt(receiptId);
        assertEq(receipt.amount, updatedUnitPrice);
        assertEq(usdc.balanceOf(buyer), buyerBalanceBefore - updatedUnitPrice);
        assertEq(usdc.balanceOf(seller), sellerBalanceBefore + updatedUnitPrice);
    }

    function test_PurchaseReceipt_ZeroPurchaseRefReverts() public {
        uint256 listingId = _createListingAsSeller();

        vm.startPrank(buyer);
        usdc.approve(address(store), unitPrice);
        vm.expectRevert(RevealReceiptStore.InvalidPurchaseRef.selector);
        store.purchaseReceipt(listingId, bytes32(0));
        vm.stopPrank();
    }

    function test_PurchaseReceipt_DuplicatePurchaseRefSameSellerReverts() public {
        uint256 listingId = _createListingAsSeller();

        _purchaseReceiptAs(listingId, buyer, purchaseRef);

        vm.startPrank(buyer2);
        usdc.approve(address(store), unitPrice);
        vm.expectRevert(RevealReceiptStore.PurchaseRefAlreadyUsed.selector);
        store.purchaseReceipt(listingId, purchaseRef);
        vm.stopPrank();
    }

    function test_PurchaseReceipt_CanonicalHashDuplicateSameSellerReverts() public {
        uint256 listingId = _createListingAsSeller();
        string memory rawPurchaseRef = _makeRawPurchaseRef(6);
        bytes32 canonicalPurchaseRef = store.hashPurchaseRef(seller, listingId, rawPurchaseRef);

        _purchaseReceiptAs(listingId, buyer, canonicalPurchaseRef);

        vm.startPrank(buyer2);
        usdc.approve(address(store), unitPrice);
        vm.expectRevert(RevealReceiptStore.PurchaseRefAlreadyUsed.selector);
        store.purchaseReceipt(listingId, canonicalPurchaseRef);
        vm.stopPrank();
    }

    function test_PurchaseReceipt_SameRawPurchaseRefAcrossListingsReverts() public {
        uint256 listingId1 = _createListingAs(seller, listingHash);
        uint256 listingId2 = _createListingAs(seller, listingHash2);
        string memory rawPurchaseRef = _makeRawPurchaseRef(7);
        bytes32 listing1PurchaseRef = store.hashPurchaseRef(seller, listingId1, rawPurchaseRef);
        bytes32 listing2PurchaseRef = store.hashPurchaseRef(seller, listingId2, rawPurchaseRef);

        assertEq(listing1PurchaseRef, listing2PurchaseRef);

        _purchaseReceiptAs(listingId1, buyer, listing1PurchaseRef);

        vm.startPrank(buyer2);
        usdc.approve(address(store), unitPrice);
        vm.expectRevert(RevealReceiptStore.PurchaseRefAlreadyUsed.selector);
        store.purchaseReceipt(listingId2, listing2PurchaseRef);
        vm.stopPrank();
    }

    function test_PurchaseReceipt_DifferentPurchaseRefsStillWork() public {
        uint256 listingId = _createListingAsSeller();

        uint256 receiptId1 = _purchaseReceiptAs(listingId, buyer, purchaseRef);
        uint256 receiptId2 = _purchaseReceiptAs(listingId, buyer2, purchaseRef2);

        assertEq(receiptId1, 1);
        assertEq(receiptId2, 2);
        assertEq(store.getReceiptIdBySellerAndPurchaseRef(seller, purchaseRef), receiptId1);
        assertEq(store.getReceiptIdBySellerAndPurchaseRef(seller, purchaseRef2), receiptId2);
        _assertRegistryConsumption(purchaseRef, address(store));
        _assertRegistryConsumption(purchaseRef2, address(store));
    }

    function test_PurchaseReceipt_PurchaseRefReplayAcrossListingsReverts() public {
        uint256 listingId1 = _createListingAs(seller, listingHash);
        uint256 listingId2 = _createListingAs(seller, listingHash2);

        _purchaseReceiptAs(listingId1, buyer, purchaseRef);

        vm.startPrank(buyer2);
        usdc.approve(address(store), unitPrice);
        vm.expectRevert(RevealReceiptStore.PurchaseRefAlreadyUsed.selector);
        store.purchaseReceipt(listingId2, purchaseRef);
        vm.stopPrank();
    }

    function test_PurchaseReceipt_PurchaseRefReplayAcrossDifferentSellersReverts() public {
        uint256 listingId1 = _createListingAs(seller, listingHash);
        uint256 listingId2 = _createListingAs(seller2, listingHash2);

        uint256 receiptId1 = _purchaseReceiptAs(listingId1, buyer, purchaseRef);

        assertEq(receiptId1, 1);
        assertEq(store.getReceiptIdBySellerAndPurchaseRef(seller, purchaseRef), receiptId1);
        assertEq(store.getReceiptIdBySellerAndPurchaseRef(seller2, purchaseRef), 0);
        _assertRegistryConsumption(purchaseRef, address(store));

        vm.startPrank(buyer2);
        usdc.approve(address(store), unitPrice);
        vm.expectRevert(RevealReceiptStore.PurchaseRefAlreadyUsed.selector);
        store.purchaseReceipt(listingId2, purchaseRef);
        vm.stopPrank();
    }

    function test_PurchaseReceipt_FailedTransferDoesNotConsumeRegistry() public {
        uint256 listingId = _createListingAsSeller();

        vm.prank(buyer);
        vm.expectRevert();
        store.purchaseReceipt(listingId, purchaseRef);

        _assertRegistryNotConsumed(purchaseRef);
        assertEq(store.getReceiptIdBySellerAndPurchaseRef(seller, purchaseRef), 0);
    }

    function test_RegistryCanBlockPurchaseEvenWhenLocalMappingEmpty() public {
        uint256 listingId = _createListingAsSeller();
        address externalConsumer = address(0xBAD);

        vm.prank(externalConsumer);
        registry.consume(purchaseRef);

        assertEq(store.getReceiptIdBySellerAndPurchaseRef(seller, purchaseRef), 0);
        assertEq(registry.consumedBy(purchaseRef), externalConsumer);

        vm.startPrank(buyer);
        usdc.approve(address(store), unitPrice);
        vm.expectRevert(RevealReceiptStore.PurchaseRefAlreadyUsed.selector);
        store.purchaseReceipt(listingId, purchaseRef);
        vm.stopPrank();
    }

    function test_PurchaseReceipt_NonexistentListingReverts() public {
        vm.startPrank(buyer);
        usdc.approve(address(store), unitPrice);
        vm.expectRevert(RevealReceiptStore.ListingNotFound.selector);
        store.purchaseReceipt(999, purchaseRef);
        vm.stopPrank();
    }

    function test_PurchaseSignedReceipt_AuthorizedSignerCanSignDynamicQuote() public {
        RevealReceiptStore feeStore = _deployStore(500);
        uint256 listingId = _createListingAs(feeStore, seller, listingHash);
        _setQuoteSigner(feeStore, seller, quoteSigner, true);

        RevealReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 days));
        bytes memory signature = _signSignedReceiptQuote(feeStore, QUOTE_SIGNER_PK, quote);
        uint256 sellerBalanceBefore = usdc.balanceOf(seller);
        uint256 buyerBalanceBefore = usdc.balanceOf(buyer);
        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);
        uint256 protocolFee = quotedAmount * 500 / 10_000;

        vm.startPrank(buyer);
        usdc.approve(address(feeStore), quotedAmount);

        vm.expectEmit(true, true, true, true);
        emit RevealReceiptStore.ProtocolFeePaid(1, listingId, feeRecipient, protocolFee);
        vm.expectEmit(true, true, true, true);
        emit RevealReceiptStore.SellerPaid(1, listingId, seller, quotedAmount - protocolFee);
        vm.expectEmit(true, true, true, true);
        emit RevealReceiptStore.ReceiptPurchased(1, seller, buyer, listingId, purchaseRef, quotedAmount, metadataHash);

        uint256 receiptId = feeStore.purchaseSignedReceipt(quote, signature);
        vm.stopPrank();

        RevealReceiptStore.Receipt memory receipt = feeStore.getReceipt(receiptId);
        assertEq(receiptId, 1);
        assertEq(receipt.amount, quotedAmount);
        assertEq(receipt.buyer, buyer);
        assertEq(receipt.seller, seller);
        assertEq(receipt.purchaseRef, purchaseRef);
        assertEq(feeStore.getReceiptIdBySellerAndPurchaseRef(seller, purchaseRef), receiptId);
        _assertRegistryConsumption(purchaseRef, address(feeStore));
        assertEq(usdc.balanceOf(buyer), buyerBalanceBefore - quotedAmount);
        assertEq(usdc.balanceOf(seller), sellerBalanceBefore + (quotedAmount - protocolFee));
        assertEq(usdc.balanceOf(feeRecipient), feeRecipientBalanceBefore + protocolFee);
        assertEq(usdc.balanceOf(address(feeStore)), 0);
    }

    function test_PurchaseSignedReceipt_DirectSellerSignatureStillWorks() public {
        RevealReceiptStore feeStore = _deployStore(500);
        uint256 listingId = _createListingAs(feeStore, seller, listingHash);
        address integrator = address(0x1A7E);
        assertFalse(feeStore.authorizedQuoteSigners(seller, seller));
        assertEq(feeStore.authorizedQuoteSignerCount(seller), 0);
        RevealReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 days));
        bytes memory signature = _signSignedReceiptQuote(feeStore, SELLER_PK, quote);
        uint256 sellerBalanceBefore = usdc.balanceOf(seller);
        uint256 buyerBalanceBefore = usdc.balanceOf(buyer);
        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);
        uint256 integratorBalanceBefore = usdc.balanceOf(integrator);
        uint256 protocolFee = quotedAmount * 500 / 10_000;

        vm.startPrank(buyer);
        usdc.approve(address(feeStore), quotedAmount);

        vm.expectEmit(true, true, true, true);
        emit RevealReceiptStore.ProtocolFeePaid(1, listingId, feeRecipient, protocolFee);
        vm.expectEmit(true, true, true, true);
        emit RevealReceiptStore.SellerPaid(1, listingId, seller, quotedAmount - protocolFee);
        vm.expectEmit(true, true, true, true);
        emit RevealReceiptStore.ReceiptPurchased(1, seller, buyer, listingId, purchaseRef, quotedAmount, metadataHash);

        uint256 receiptId = feeStore.purchaseSignedReceipt(quote, signature);
        vm.stopPrank();

        RevealReceiptStore.Receipt memory receipt = feeStore.getReceipt(receiptId);
        assertEq(receiptId, 1);
        assertEq(receipt.amount, quotedAmount);
        assertEq(receipt.buyer, buyer);
        assertEq(receipt.seller, seller);
        assertEq(receipt.purchaseRef, purchaseRef);
        assertEq(feeStore.getReceiptIdBySellerAndPurchaseRef(seller, purchaseRef), receiptId);
        assertEq(usdc.balanceOf(buyer), buyerBalanceBefore - quotedAmount);
        assertEq(usdc.balanceOf(seller), sellerBalanceBefore + (quotedAmount - protocolFee));
        assertEq(usdc.balanceOf(feeRecipient), feeRecipientBalanceBefore + protocolFee);
        assertEq(usdc.balanceOf(integrator), integratorBalanceBefore);
        assertEq(usdc.balanceOf(address(feeStore)), 0);
        assertFalse(feeStore.authorizedQuoteSigners(seller, seller));
        assertEq(feeStore.authorizedQuoteSignerCount(seller), 0);
    }

    function test_PurchaseSignedReceipt_PaysIntegratorFeeAndSellerNet() public {
        RevealReceiptStore feeStore = _deployStore(500);
        uint256 listingId = _createListingAs(feeStore, seller, listingHash);
        address integrator = address(0x1A7E);
        uint256 integratorFeeAmount = quotedAmount * 200 / 10_000;
        RevealReceiptStore.SignedReceiptQuote memory quote = _makeSignedReceiptQuoteWithIntegrator(
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
        uint256 protocolFee = quotedAmount * 500 / 10_000;

        vm.startPrank(buyer);
        usdc.approve(address(feeStore), quotedAmount);

        vm.expectEmit(true, true, true, true);
        emit RevealReceiptStore.ProtocolFeePaid(1, listingId, feeRecipient, protocolFee);
        vm.expectEmit(true, true, true, true);
        emit RevealReceiptStore.IntegratorFeePaid(1, listingId, integrator, integratorFeeAmount);
        vm.expectEmit(true, true, true, true);
        emit RevealReceiptStore.SellerPaid(1, listingId, seller, quotedAmount - protocolFee - integratorFeeAmount);
        vm.expectEmit(true, true, true, true);
        emit RevealReceiptStore.ReceiptPurchased(1, seller, buyer, listingId, purchaseRef, quotedAmount, metadataHash);

        uint256 receiptId = feeStore.purchaseSignedReceipt(quote, signature);
        vm.stopPrank();

        RevealReceiptStore.Receipt memory receipt = feeStore.getReceipt(receiptId);
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

    function test_PurchaseSignedReceipt_MaxProtocolAndMaxIntegratorFeeSettles() public {
        RevealReceiptStore maxFeeStore = _deployStore(uint16(store.MAX_PROTOCOL_FEE_BPS()));
        uint256 listingId = _createListingAs(maxFeeStore, seller, listingHash);
        address integrator = address(0x1A7E);
        uint256 integratorFeeAmount = quotedAmount * maxFeeStore.MAX_INTEGRATOR_FEE_BPS() / 10_000;
        uint256 protocolFee = quotedAmount * maxFeeStore.MAX_PROTOCOL_FEE_BPS() / 10_000;
        RevealReceiptStore.SignedReceiptQuote memory quote = _makeSignedReceiptQuoteWithIntegrator(
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
        RevealReceiptStore feeStore = _deployStore(500);
        uint256 listingId = _createListingAs(feeStore, seller, listingHash);
        RevealReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 days));
        bytes memory signature = _signSignedReceiptQuote(feeStore, SELLER_PK, quote);
        uint256 protocolFee = quotedAmount * 500 / 10_000;

        uint256 receiptId = _purchaseSignedReceiptAs(feeStore, buyer, quote, signature);

        RevealReceiptStore.Listing memory listing = feeStore.getListing(listingId);
        RevealReceiptStore.Receipt memory receipt = feeStore.getReceipt(receiptId);
        assertEq(listing.unitPrice, unitPrice);
        assertEq(receipt.amount, quotedAmount);
        assertEq(usdc.balanceOf(feeRecipient), protocolFee);
    }

    function test_PurchaseSignedReceipt_UnauthorizedSignerFails() public {
        uint256 listingId = _createListingAsSeller();
        RevealReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 days));
        bytes memory signature = _signSignedReceiptQuote(store, ATTACKER_PK, quote);

        vm.startPrank(buyer);
        usdc.approve(address(store), quotedAmount);
        vm.expectRevert(RevealReceiptStore.InvalidQuoteSigner.selector);
        store.purchaseSignedReceipt(quote, signature);
        vm.stopPrank();
    }

    function test_PurchaseSignedReceipt_RevokedSignerQuoteFails() public {
        uint256 listingId = _createListingAsSeller();
        _setQuoteSigner(store, seller, quoteSigner, true);

        RevealReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 days));
        bytes memory signature = _signSignedReceiptQuote(store, QUOTE_SIGNER_PK, quote);

        _setQuoteSigner(store, seller, quoteSigner, false);

        vm.startPrank(buyer);
        usdc.approve(address(store), quotedAmount);
        vm.expectRevert(RevealReceiptStore.InvalidQuoteSigner.selector);
        store.purchaseSignedReceipt(quote, signature);
        vm.stopPrank();
    }

    function test_PurchaseSignedReceipt_AuthorizationCheckedAtPurchaseTime() public {
        RevealReceiptStore feeStore = _deployStore(500);
        uint256 listingId = _createListingAs(feeStore, seller, listingHash);
        _setQuoteSigner(feeStore, seller, quoteSigner, true);

        RevealReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 days));
        bytes memory signature = _signSignedReceiptQuote(feeStore, QUOTE_SIGNER_PK, quote);

        _setQuoteSigner(feeStore, seller, quoteSigner, false);

        vm.startPrank(buyer);
        usdc.approve(address(feeStore), quotedAmount);
        vm.expectRevert(RevealReceiptStore.InvalidQuoteSigner.selector);
        feeStore.purchaseSignedReceipt(quote, signature);
        vm.stopPrank();
    }

    function test_PurchaseSignedReceipt_WrongBuyerReverts() public {
        uint256 listingId = _createListingAsSeller();
        RevealReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 days));
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        vm.startPrank(attacker);
        usdc.approve(address(store), quotedAmount);
        vm.expectRevert(RevealReceiptStore.QuoteBuyerMismatch.selector);
        store.purchaseSignedReceipt(quote, signature);
        vm.stopPrank();
    }

    function test_PurchaseSignedReceipt_InternalPayerCanDifferFromReceiptBuyer() public {
        RevealReceiptStoreHarness harnessStore = _deployHarnessStore(0);
        uint256 listingId = _createListingAs(harnessStore, seller, listingHash);
        RevealReceiptStore.SignedReceiptQuote memory quote =
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

        RevealReceiptStore.Receipt memory receipt = harnessStore.getReceipt(receiptId);

        assertEq(receiptId, 1);
        assertEq(receipt.buyer, buyer);
        assertEq(receipt.seller, seller);
        assertEq(receipt.amount, quotedAmount);
        assertEq(receipt.purchaseRef, purchaseRef);
        assertEq(harnessStore.getReceiptIdBySellerAndPurchaseRef(seller, purchaseRef), receiptId);
        assertEq(usdc.balanceOf(gatewayAdapter), gatewayAdapterBalanceBefore - quotedAmount);
        assertEq(usdc.balanceOf(buyer), buyerBalanceBefore);
        assertEq(usdc.balanceOf(seller), sellerBalanceBefore + quotedAmount);
        assertEq(usdc.balanceOf(address(harnessStore)), 0);
    }

    function test_PurchaseSignedReceipt_InternalPayerCanDifferFromReceiptBuyerWithIntegratorFee() public {
        RevealReceiptStoreHarness harnessStore = _deployHarnessStore(500);
        uint256 listingId = _createListingAs(harnessStore, seller, listingHash);
        address gatewayAdapter = address(0xADA702);
        address integrator = address(0x1A7E);
        uint256 integratorFeeAmount = quotedAmount * 200 / 10_000;

        RevealReceiptStore.SignedReceiptQuote memory quote = _makeSignedReceiptQuoteWithIntegrator(
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

        RevealReceiptStore.Receipt memory receipt = harnessStore.getReceipt(receiptId);

        assertEq(receiptId, 1);
        assertEq(receipt.buyer, buyer);
        assertEq(receipt.seller, seller);
        assertEq(receipt.amount, quotedAmount);
        assertEq(receipt.purchaseRef, purchaseRef);
        assertEq(usdc.balanceOf(gatewayAdapter), 0);
        assertEq(usdc.balanceOf(buyer), 10_000_000_000);
        assertEq(usdc.balanceOf(feeRecipient), quotedAmount * 500 / 10_000);
        assertEq(usdc.balanceOf(integrator), integratorFeeAmount);
        assertEq(usdc.balanceOf(seller), quotedAmount - (quotedAmount * 500 / 10_000) - integratorFeeAmount);
        assertEq(usdc.balanceOf(address(harnessStore)), 0);
    }

    function test_PurchaseSignedReceipt_ExpiredQuoteReverts() public {
        uint256 listingId = _createListingAsSeller();
        RevealReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp - 1));
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        vm.startPrank(buyer);
        usdc.approve(address(store), quotedAmount);
        vm.expectRevert(RevealReceiptStore.QuoteExpired.selector);
        store.purchaseSignedReceipt(quote, signature);
        vm.stopPrank();
    }

    function test_PurchaseSignedReceipt_QuoteExpiringExactlyNowReverts() public {
        uint256 listingId = _createListingAsSeller();
        RevealReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, 0);
        quote.expiresAt = uint64(block.timestamp);
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        vm.startPrank(buyer);
        usdc.approve(address(store), quotedAmount);
        vm.expectRevert(RevealReceiptStore.QuoteExpired.selector);
        store.purchaseSignedReceipt(quote, signature);
        vm.stopPrank();
    }

    function test_PurchaseSignedReceipt_QuoteExpiringInFutureSucceeds() public {
        RevealReceiptStore feeStore = _deployStore(500);
        uint256 listingId = _createListingAs(feeStore, seller, listingHash);
        RevealReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, 0);
        quote.expiresAt = uint64(block.timestamp + 1 hours);
        bytes memory signature = _signSignedReceiptQuote(feeStore, SELLER_PK, quote);
        uint256 sellerBalanceBefore = usdc.balanceOf(seller);
        uint256 buyerBalanceBefore = usdc.balanceOf(buyer);
        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);
        uint256 protocolFee = quotedAmount * 500 / 10_000;

        vm.startPrank(buyer);
        usdc.approve(address(feeStore), quotedAmount);

        vm.expectEmit(true, true, true, true);
        emit RevealReceiptStore.ProtocolFeePaid(1, listingId, feeRecipient, protocolFee);
        vm.expectEmit(true, true, true, true);
        emit RevealReceiptStore.SellerPaid(1, listingId, seller, quotedAmount - protocolFee);
        vm.expectEmit(true, true, true, true);
        emit RevealReceiptStore.ReceiptPurchased(1, seller, buyer, listingId, purchaseRef, quotedAmount, metadataHash);

        uint256 receiptId = feeStore.purchaseSignedReceipt(quote, signature);
        vm.stopPrank();

        RevealReceiptStore.Receipt memory receipt = feeStore.getReceipt(receiptId);
        assertEq(receiptId, 1);
        assertEq(receipt.amount, quotedAmount);
        assertEq(usdc.balanceOf(buyer), buyerBalanceBefore - quotedAmount);
        assertEq(usdc.balanceOf(seller), sellerBalanceBefore + (quotedAmount - protocolFee));
        assertEq(usdc.balanceOf(feeRecipient), feeRecipientBalanceBefore + protocolFee);
    }

    function test_PurchaseSignedReceipt_QuoteExpiryBeyondMaxTtlReverts() public {
        uint256 listingId = _createListingAsSeller();
        RevealReceiptStore.SignedReceiptQuote memory quote = _makeSignedReceiptQuote(
            listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + store.MAX_QUOTE_TTL() + 1)
        );
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        vm.startPrank(buyer);
        usdc.approve(address(store), quotedAmount);
        vm.expectRevert(RevealReceiptStore.QuoteExpiryTooLong.selector);
        store.purchaseSignedReceipt(quote, signature);
        vm.stopPrank();
    }

    function test_PurchaseSignedReceipt_QuoteExpiryAtMaxTtlSucceeds() public {
        uint256 listingId = _createListingAsSeller();
        RevealReceiptStore.SignedReceiptQuote memory quote = _makeSignedReceiptQuote(
            listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + store.MAX_QUOTE_TTL())
        );
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        uint256 receiptId = _purchaseSignedReceiptAs(store, buyer, quote, signature);
        assertEq(receiptId, 1);
    }

    function test_PurchaseSignedReceipt_QuoteAmountBelowMinReverts() public {
        uint256 listingId = _createListingAsSeller();
        RevealReceiptStore.SignedReceiptQuote memory quote = _makeSignedReceiptQuote(
            listingId, buyer, purchaseRef, store.MIN_PURCHASE_AMOUNT() - 1, uint64(block.timestamp + 1 days)
        );
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        vm.startPrank(buyer);
        usdc.approve(address(store), quote.amount);
        vm.expectRevert(RevealReceiptStore.AmountOutOfBounds.selector);
        store.purchaseSignedReceipt(quote, signature);
        vm.stopPrank();
    }

    function test_PurchaseSignedReceipt_QuoteAmountAtMinSucceeds() public {
        uint256 listingId = _createListingAsSeller();
        RevealReceiptStore.SignedReceiptQuote memory quote = _makeSignedReceiptQuote(
            listingId, buyer, purchaseRef, store.MIN_PURCHASE_AMOUNT(), uint64(block.timestamp + 1 days)
        );
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        uint256 receiptId = _purchaseSignedReceiptAs(store, buyer, quote, signature);
        assertEq(store.getReceipt(receiptId).amount, store.MIN_PURCHASE_AMOUNT());
    }

    function test_PurchaseSignedReceipt_QuoteAmountAtMaxSucceeds() public {
        uint256 listingId = _createListingAsSeller();
        RevealReceiptStore.SignedReceiptQuote memory quote = _makeSignedReceiptQuote(
            listingId, buyer, purchaseRef, store.MAX_PURCHASE_AMOUNT(), uint64(block.timestamp + 1 days)
        );
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        uint256 receiptId = _purchaseSignedReceiptAs(store, buyer, quote, signature);
        assertEq(store.getReceipt(receiptId).amount, store.MAX_PURCHASE_AMOUNT());
    }

    function test_PurchaseSignedReceipt_QuoteAmountAboveMaxReverts() public {
        uint256 listingId = _createListingAsSeller();
        RevealReceiptStore.SignedReceiptQuote memory quote = _makeSignedReceiptQuote(
            listingId, buyer, purchaseRef, store.MAX_PURCHASE_AMOUNT() + 1, uint64(block.timestamp + 1 days)
        );
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        vm.startPrank(buyer);
        usdc.approve(address(store), quote.amount);
        vm.expectRevert(RevealReceiptStore.AmountOutOfBounds.selector);
        store.purchaseSignedReceipt(quote, signature);
        vm.stopPrank();
    }

    function test_PurchaseSignedReceipt_IntegratorRecipientWithoutFeeReverts() public {
        uint256 listingId = _createListingAsSeller();
        RevealReceiptStore.SignedReceiptQuote memory quote = _makeSignedReceiptQuoteWithIntegrator(
            listingId, buyer, purchaseRef, quotedAmount, address(0x1A7E), 0, uint64(block.timestamp + 1 days)
        );
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        vm.startPrank(buyer);
        usdc.approve(address(store), quotedAmount);
        vm.expectRevert(RevealReceiptStore.InvalidParams.selector);
        store.purchaseSignedReceipt(quote, signature);
        vm.stopPrank();
    }

    function test_PurchaseSignedReceipt_IntegratorFeeWithoutRecipientReverts() public {
        uint256 listingId = _createListingAsSeller();
        RevealReceiptStore.SignedReceiptQuote memory quote = _makeSignedReceiptQuoteWithIntegrator(
            listingId, buyer, purchaseRef, quotedAmount, address(0), 1, uint64(block.timestamp + 1 days)
        );
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        vm.startPrank(buyer);
        usdc.approve(address(store), quotedAmount);
        vm.expectRevert(RevealReceiptStore.InvalidParams.selector);
        store.purchaseSignedReceipt(quote, signature);
        vm.stopPrank();
    }

    function test_PurchaseSignedReceipt_IntegratorFeeTooHighReverts() public {
        uint256 listingId = _createListingAsSeller();
        uint256 integratorFeeAmount = quotedAmount * 1001 / 10_000;
        RevealReceiptStore.SignedReceiptQuote memory quote = _makeSignedReceiptQuoteWithIntegrator(
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
        vm.expectRevert(RevealReceiptStore.IntegratorFeeTooHigh.selector);
        store.purchaseSignedReceipt(quote, signature);
        vm.stopPrank();
    }

    function test_PurchaseSignedReceipt_ZeroPurchaseRefReverts() public {
        uint256 listingId = _createListingAsSeller();
        RevealReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, bytes32(0), quotedAmount, uint64(block.timestamp + 1 days));
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        vm.startPrank(buyer);
        usdc.approve(address(store), quotedAmount);
        vm.expectRevert(RevealReceiptStore.InvalidPurchaseRef.selector);
        store.purchaseSignedReceipt(quote, signature);
        vm.stopPrank();
    }

    function test_PurchaseSignedReceipt_ZeroMetadataHashReverts() public {
        uint256 listingId = _createListingAsSeller();
        RevealReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 days));
        quote.metadataHash = bytes32(0);
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        vm.startPrank(buyer);
        usdc.approve(address(store), quotedAmount);
        vm.expectRevert(RevealReceiptStore.InvalidParams.selector);
        store.purchaseSignedReceipt(quote, signature);
        vm.stopPrank();
    }

    function test_PurchaseSignedReceipt_DuplicatePurchaseRefSameSellerReverts() public {
        uint256 listingId = _createListingAsSeller();
        RevealReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 days));
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        uint256 receiptId = _purchaseSignedReceiptAs(store, buyer, quote, signature);

        vm.startPrank(buyer);
        usdc.approve(address(store), quotedAmount);
        vm.expectRevert(RevealReceiptStore.PurchaseRefAlreadyUsed.selector);
        store.purchaseSignedReceipt(quote, signature);
        vm.stopPrank();

        assertEq(receiptId, 1);
    }

    function test_PurchaseSignedReceipt_InactiveListingReverts() public {
        uint256 listingId = _createListingAsSeller();
        RevealReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 days));
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        vm.prank(seller);
        store.setListingActive(listingId, false);

        vm.startPrank(buyer);
        usdc.approve(address(store), quotedAmount);
        vm.expectRevert(RevealReceiptStore.ListingInactive.selector);
        store.purchaseSignedReceipt(quote, signature);
        vm.stopPrank();
    }

    function test_PurchaseSignedReceipt_AuthorizationIsSellerScoped() public {
        uint256 sellerAListingId = _createListingAs(seller, listingHash);
        uint256 sellerBListingId = _createListingAs(store, seller2, listingHash2);
        _setQuoteSigner(store, seller, quoteSigner, true);

        RevealReceiptStore.SignedReceiptQuote memory sellerBQuote = _makeSignedReceiptQuote(
            sellerBListingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 days)
        );
        bytes memory sellerBSignature = _signSignedReceiptQuote(store, QUOTE_SIGNER_PK, sellerBQuote);

        vm.startPrank(buyer);
        usdc.approve(address(store), quotedAmount);
        vm.expectRevert(RevealReceiptStore.InvalidQuoteSigner.selector);
        store.purchaseSignedReceipt(sellerBQuote, sellerBSignature);
        vm.stopPrank();

        RevealReceiptStore.SignedReceiptQuote memory sellerAQuote = _makeSignedReceiptQuote(
            sellerAListingId, buyer, purchaseRef2, quotedAmount, uint64(block.timestamp + 1 days)
        );
        bytes memory sellerASignature = _signSignedReceiptQuote(store, QUOTE_SIGNER_PK, sellerAQuote);

        uint256 receiptId = _purchaseSignedReceiptAs(store, buyer, sellerAQuote, sellerASignature);
        assertEq(receiptId, 1);
        assertEq(store.getReceiptIdBySellerAndPurchaseRef(seller, purchaseRef2), receiptId);
    }

    function test_PurchaseSignedReceipt_PurchaseRefReplayAcrossDifferentSellersReverts() public {
        uint256 listingId1 = _createListingAs(seller, listingHash);
        uint256 listingId2 = _createListingAs(store, seller2, listingHash2);
        RevealReceiptStore.SignedReceiptQuote memory quote1 =
            _makeSignedReceiptQuote(listingId1, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 days));
        RevealReceiptStore.SignedReceiptQuote memory quote2 =
            _makeSignedReceiptQuote(listingId2, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 days));
        bytes memory signature1 = _signSignedReceiptQuote(store, SELLER_PK, quote1);
        bytes memory signature2 = _signSignedReceiptQuote(store, SELLER2_PK, quote2);

        uint256 receiptId1 = _purchaseSignedReceiptAs(store, buyer, quote1, signature1);

        assertEq(receiptId1, 1);
        assertEq(store.getReceiptIdBySellerAndPurchaseRef(seller, purchaseRef), receiptId1);
        assertEq(store.getReceiptIdBySellerAndPurchaseRef(seller2, purchaseRef), 0);
        _assertRegistryConsumption(purchaseRef, address(store));

        vm.startPrank(buyer);
        usdc.approve(address(store), quotedAmount);
        vm.expectRevert(RevealReceiptStore.PurchaseRefAlreadyUsed.selector);
        store.purchaseSignedReceipt(quote2, signature2);
        vm.stopPrank();
    }

    function test_PurchaseSignedReceipt_SharedRegistryBlocksReplayAcrossStores() public {
        RevealReceiptStore secondStore = _deployStore(0, address(this), registry);
        uint256 listingId1 = _createListingAs(store, seller, listingHash);
        uint256 listingId2 = _createListingAs(secondStore, seller2, listingHash2);
        RevealReceiptStore.SignedReceiptQuote memory quote1 =
            _makeSignedReceiptQuote(listingId1, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 days));
        RevealReceiptStore.SignedReceiptQuote memory quote2 =
            _makeSignedReceiptQuote(listingId2, buyer2, purchaseRef, quotedAmount, uint64(block.timestamp + 1 days));
        bytes memory signature1 = _signSignedReceiptQuote(store, SELLER_PK, quote1);
        bytes memory signature2 = _signSignedReceiptQuote(secondStore, SELLER2_PK, quote2);

        uint256 receiptId = _purchaseSignedReceiptAs(store, buyer, quote1, signature1);

        assertEq(receiptId, 1);
        assertEq(registry.consumedBy(purchaseRef), address(store));
        assertEq(secondStore.getReceiptIdBySellerAndPurchaseRef(seller2, purchaseRef), 0);

        vm.startPrank(buyer2);
        usdc.approve(address(secondStore), quotedAmount);
        vm.expectRevert(RevealReceiptStore.PurchaseRefAlreadyUsed.selector);
        secondStore.purchaseSignedReceipt(quote2, signature2);
        vm.stopPrank();
    }

    function test_PurchaseSignedReceipt_SignatureFromStoreCannotBeUsedOnSecondStore() public {
        RevealReceiptStore secondStore = _deployStore(0, address(this), registry);
        uint256 listingId1 = _createListingAs(store, seller, listingHash);
        uint256 listingId2 = _createListingAs(secondStore, seller, listingHash);
        RevealReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId1, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 days));
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        vm.startPrank(buyer);
        usdc.approve(address(secondStore), quotedAmount);
        vm.expectRevert(RevealReceiptStore.InvalidQuoteSigner.selector);
        secondStore.purchaseSignedReceipt(
            RevealReceiptStore.SignedReceiptQuote({
                listingId: listingId2,
                buyer: quote.buyer,
                purchaseRef: quote.purchaseRef,
                amount: quote.amount,
                metadataHash: quote.metadataHash,
                integratorFeeRecipient: quote.integratorFeeRecipient,
                integratorFeeAmount: quote.integratorFeeAmount,
                expiresAt: quote.expiresAt
            }),
            signature
        );
        vm.stopPrank();
    }

    function test_PurchaseSignedReceipt_FailedTransferDoesNotConsumeRegistry() public {
        uint256 listingId = _createListingAsSeller();
        RevealReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 days));
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        vm.prank(buyer);
        vm.expectRevert();
        store.purchaseSignedReceipt(quote, signature);

        _assertRegistryNotConsumed(purchaseRef);
        assertEq(store.getReceiptIdBySellerAndPurchaseRef(seller, purchaseRef), 0);
    }

    function test_HashSignedReceiptQuote_MatchesTestGeneratedEIP712Digest() public {
        uint256 listingId = _createListingAsSeller();
        RevealReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 days));

        bytes32 digest = store.hashSignedReceiptQuote(quote);
        bytes32 expectedDigest = _expectedSignedReceiptQuoteDigest(store, quote);
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);
        address recoveredSigner = ECDSA.recover(digest, signature);

        assertEq(digest, expectedDigest);
        assertEq(recoveredSigner, seller);
    }

    function test_HashSignedReceiptQuote_DependsOnPurchaseRefRegistry() public {
        PurchaseRefRegistry secondRegistry = new PurchaseRefRegistry();
        RevealReceiptStore secondStoreWithDifferentRegistry = _deployStore(0, address(this), secondRegistry);
        uint256 listingId1 = _createListingAs(store, seller, listingHash);
        uint256 listingId2 = _createListingAs(secondStoreWithDifferentRegistry, seller, listingHash);
        RevealReceiptStore.SignedReceiptQuote memory quote1 =
            _makeSignedReceiptQuote(listingId1, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 days));
        RevealReceiptStore.SignedReceiptQuote memory quote2 =
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

        bytes32 purchaseRefHash = store.hashPurchaseRef(seller, listingId, rawPurchaseRef);
        bytes32 expectedHash = _expectedPurchaseRefHash(seller, rawPurchaseRef);

        assertEq(purchaseRefHash, expectedHash);
    }

    function test_HashPurchaseRef_DoesNotDependOnReceiptStoreAddress() public {
        RevealReceiptStore secondStore = _deployStore(0, address(this), registry);
        string memory rawPurchaseRef = _makeRawPurchaseRef(5);

        uint256 firstListingId = _createListingAs(store, seller, listingHash);
        uint256 secondListingId = _createListingAs(secondStore, seller, listingHash);

        bytes32 firstHash = store.hashPurchaseRef(seller, firstListingId, rawPurchaseRef);
        bytes32 secondHash = secondStore.hashPurchaseRef(seller, secondListingId, rawPurchaseRef);

        assertEq(firstListingId, secondListingId);
        assertEq(firstHash, secondHash);
    }

    function test_PurchaseReceipt_SharedRegistryBlocksReplayAcrossStores() public {
        RevealReceiptStore secondStore = _deployStore(0, address(this), registry);
        uint256 firstListingId = _createListingAs(store, seller, listingHash);
        uint256 secondListingId = _createListingAs(secondStore, seller2, listingHash2);

        uint256 receiptId = _purchaseReceiptAs(store, firstListingId, buyer, purchaseRef);

        assertEq(receiptId, 1);
        _assertRegistryConsumption(purchaseRef, address(store));
        assertEq(secondStore.getReceiptIdBySellerAndPurchaseRef(seller2, purchaseRef), 0);

        vm.startPrank(buyer2);
        usdc.approve(address(secondStore), unitPrice);
        vm.expectRevert(RevealReceiptStore.PurchaseRefAlreadyUsed.selector);
        secondStore.purchaseReceipt(secondListingId, purchaseRef);
        vm.stopPrank();
    }

    function test_HashPurchaseRef_SameInputsReturnSameHash() public {
        uint256 listingId = _createListingAsSeller();
        string memory rawPurchaseRef = _makeRawPurchaseRef(2);

        bytes32 firstHash = store.hashPurchaseRef(seller, listingId, rawPurchaseRef);
        bytes32 secondHash = store.hashPurchaseRef(seller, listingId, rawPurchaseRef);

        assertEq(firstHash, secondHash);
    }

    function test_HashPurchaseRef_DifferentRawPurchaseRefReturnsDifferentHash() public {
        uint256 listingId = _createListingAsSeller();
        string memory firstRawPurchaseRef = _makeRawPurchaseRef(8);
        string memory secondRawPurchaseRef = _makeRawPurchaseRef(9);

        bytes32 firstHash = store.hashPurchaseRef(seller, listingId, firstRawPurchaseRef);
        bytes32 secondHash = store.hashPurchaseRef(seller, listingId, secondRawPurchaseRef);

        assertNotEq(firstHash, secondHash);
    }

    function test_HashPurchaseRef_DoesNotDependOnListingId() public {
        uint256 listingId1 = _createListingAs(seller, listingHash);
        uint256 listingId2 = _createListingAs(seller, listingHash2);
        string memory rawPurchaseRef = _makeRawPurchaseRef(3);

        bytes32 firstHash = store.hashPurchaseRef(seller, listingId1, rawPurchaseRef);
        bytes32 secondHash = store.hashPurchaseRef(seller, listingId2, rawPurchaseRef);

        assertEq(firstHash, secondHash);
    }

    function test_HashPurchaseRef_DifferentSettlementTokenReturnsDifferentHash() public {
        ReceiptMockUSDC secondUsdc = new ReceiptMockUSDC();
        RevealReceiptStore secondStore =
            new RevealReceiptStore(address(secondUsdc), address(registry), feeRecipient, 0, address(this));
        uint256 listingId1 = _createListingAs(store, seller, listingHash);
        uint256 listingId2 = _createListingAs(secondStore, seller, listingHash);
        string memory rawPurchaseRef = _makeRawPurchaseRef(10);

        bytes32 firstHash = store.hashPurchaseRef(seller, listingId1, rawPurchaseRef);
        bytes32 secondHash = secondStore.hashPurchaseRef(seller, listingId2, rawPurchaseRef);

        assertNotEq(firstHash, secondHash);
    }

    function test_HashPurchaseRef_DifferentSellerReturnsDifferentHash() public {
        uint256 listingId1 = _createListingAs(seller, listingHash);
        uint256 listingId2 = _createListingAs(seller2, listingHash2);
        string memory rawPurchaseRef = _makeRawPurchaseRef(4);

        bytes32 firstHash = store.hashPurchaseRef(seller, listingId1, rawPurchaseRef);
        bytes32 secondHash = store.hashPurchaseRef(seller2, listingId2, rawPurchaseRef);

        assertNotEq(firstHash, secondHash);
    }

    function test_HashPurchaseRef_ListingIdOnlyValidatesOwnership() public {
        uint256 sellerListingId = _createListingAs(seller, listingHash);
        uint256 seller2ListingId = _createListingAs(seller2, listingHash2);
        string memory rawPurchaseRef = _makeRawPurchaseRef(11);

        bytes32 hash = store.hashPurchaseRef(seller, sellerListingId, rawPurchaseRef);
        assertEq(hash, _expectedPurchaseRefHash(seller, rawPurchaseRef));

        vm.expectRevert(RevealReceiptStore.InvalidParams.selector);
        store.hashPurchaseRef(seller, seller2ListingId, rawPurchaseRef);
    }

    function test_HashPurchaseRef_EmptyRawPurchaseRefReverts() public {
        uint256 listingId = _createListingAsSeller();

        vm.expectRevert(RevealReceiptStore.InvalidPurchaseRef.selector);
        store.hashPurchaseRef(seller, listingId, "");
    }

    function test_HashPurchaseRef_RawPurchaseRefTooLongReverts() public {
        uint256 listingId = _createListingAsSeller();
        string memory rawPurchaseRef = _makeStringOfLength(129);

        vm.expectRevert(RevealReceiptStore.InvalidPurchaseRef.selector);
        store.hashPurchaseRef(seller, listingId, rawPurchaseRef);
    }

    function test_PurchaseSignedReceipt_MetadataHashMismatchInvalidatesSignature() public {
        uint256 listingId = _createListingAsSeller();
        RevealReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 days));
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        quote.metadataHash = metadataHash2;

        vm.startPrank(buyer);
        usdc.approve(address(store), quotedAmount);
        vm.expectRevert(RevealReceiptStore.InvalidQuoteSigner.selector);
        store.purchaseSignedReceipt(quote, signature);
        vm.stopPrank();
    }

    function test_ValidateSignedReceiptPurchase_ReturnsExpectedValues() public {
        RevealReceiptStore feeStore = _deployStore(500);
        uint256 listingId = _createListingAs(feeStore, seller, listingHash);
        _setQuoteSigner(feeStore, seller, quoteSigner, true);
        address integrator = address(0x1A7E);
        uint256 integratorFeeAmount = quotedAmount * 200 / 10_000;
        uint256 protocolFeeAmount = quotedAmount * 500 / 10_000;
        RevealReceiptStore.SignedReceiptQuote memory quote = _makeSignedReceiptQuoteWithIntegrator(
            listingId,
            buyer,
            purchaseRef,
            quotedAmount,
            integrator,
            integratorFeeAmount,
            uint64(block.timestamp + 1 hours)
        );
        bytes memory signature = _signSignedReceiptQuote(feeStore, QUOTE_SIGNER_PK, quote);

        (
            uint256 grossAmount,
            uint256 protocolFee,
            uint256 integratorFee,
            uint256 sellerNet,
            address protocolFeeRecipient,
            address quotedIntegratorFeeRecipient,
            address quotedSeller,
            bytes32 quotedListingHash,
            address recoveredSigner
        ) = feeStore.validateSignedReceiptPurchase(quote, signature, buyer);

        assertEq(grossAmount, quotedAmount);
        assertEq(protocolFee, protocolFeeAmount);
        assertEq(integratorFee, integratorFeeAmount);
        assertEq(sellerNet, quotedAmount - protocolFeeAmount - integratorFeeAmount);
        assertEq(protocolFeeRecipient, feeRecipient);
        assertEq(quotedIntegratorFeeRecipient, integrator);
        assertEq(quotedSeller, seller);
        assertEq(quotedListingHash, listingHash);
        assertEq(recoveredSigner, quoteSigner);
    }

    function test_ValidateSignedReceiptPurchase_InvalidSignatureReverts() public {
        uint256 listingId = _createListingAsSeller();
        RevealReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 hours));
        bytes memory signature = _signSignedReceiptQuote(store, ATTACKER_PK, quote);

        vm.expectRevert(RevealReceiptStore.InvalidQuoteSigner.selector);
        store.validateSignedReceiptPurchase(quote, signature, buyer);
    }

    function test_ValidateSignedReceiptPurchase_WrongExpectedBuyerReverts() public {
        uint256 listingId = _createListingAsSeller();
        RevealReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 hours));
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        vm.expectRevert(RevealReceiptStore.QuoteBuyerMismatch.selector);
        store.validateSignedReceiptPurchase(quote, signature, attacker);
    }

    function test_ValidateSignedReceiptPurchase_ExpiredQuoteReverts() public {
        uint256 listingId = _createListingAsSeller();
        RevealReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp - 1));
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        vm.expectRevert(RevealReceiptStore.QuoteExpired.selector);
        store.validateSignedReceiptPurchase(quote, signature, buyer);
    }

    function test_ValidateSignedReceiptPurchase_QuoteExpiryTooLongReverts() public {
        uint256 listingId = _createListingAsSeller();
        RevealReceiptStore.SignedReceiptQuote memory quote = _makeSignedReceiptQuote(
            listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + store.MAX_QUOTE_TTL() + 1)
        );
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        vm.expectRevert(RevealReceiptStore.QuoteExpiryTooLong.selector);
        store.validateSignedReceiptPurchase(quote, signature, buyer);
    }

    function test_ValidateSignedReceiptPurchase_InactiveListingReverts() public {
        uint256 listingId = _createListingAsSeller();
        RevealReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 hours));
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        vm.prank(seller);
        store.setListingActive(listingId, false);

        vm.expectRevert(RevealReceiptStore.ListingInactive.selector);
        store.validateSignedReceiptPurchase(quote, signature, buyer);
    }

    function test_ValidateSignedReceiptPurchase_ZeroPurchaseRefReverts() public {
        uint256 listingId = _createListingAsSeller();
        RevealReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, bytes32(0), quotedAmount, uint64(block.timestamp + 1 hours));
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        vm.expectRevert(RevealReceiptStore.InvalidPurchaseRef.selector);
        store.validateSignedReceiptPurchase(quote, signature, buyer);
    }

    function test_ValidateSignedReceiptPurchase_RegistryConsumedRefRevertsEvenWithoutLocalReceipt() public {
        uint256 listingId = _createListingAsSeller();
        RevealReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 hours));
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);
        address externalConsumer = address(0xBAD);

        vm.prank(externalConsumer);
        registry.consume(purchaseRef);

        assertEq(store.getReceiptIdBySellerAndPurchaseRef(seller, purchaseRef), 0);

        vm.expectRevert(RevealReceiptStore.PurchaseRefAlreadyUsed.selector);
        store.validateSignedReceiptPurchase(quote, signature, buyer);
    }

    function test_ValidateSignedReceiptPurchase_UsedPurchaseRefReverts() public {
        uint256 listingId = _createListingAsSeller();
        RevealReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 hours));
        bytes memory signature = _signSignedReceiptQuote(store, SELLER_PK, quote);

        uint256 receiptId = _purchaseSignedReceiptAs(store, buyer, quote, signature);

        vm.expectRevert(RevealReceiptStore.PurchaseRefAlreadyUsed.selector);
        store.validateSignedReceiptPurchase(quote, signature, buyer);
        assertEq(receiptId, 1);
        assertEq(store.getReceiptIdBySellerAndPurchaseRef(seller, purchaseRef), receiptId);
    }

    function test_PreviewSignedReceiptPurchase_ReturnsExpectedValues() public {
        RevealReceiptStore feeStore = _deployStore(500);
        uint256 listingId = _createListingAs(feeStore, seller, listingHash);
        RevealReceiptStore.SignedReceiptQuote memory quote =
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
        assertEq(protocolFee, quotedAmount * 500 / 10_000);
        assertEq(integratorFee, 0);
        assertEq(sellerNet, quotedAmount - protocolFee);
        assertEq(quotedFeeRecipient, feeRecipient);
        assertEq(quotedIntegratorFeeRecipient, address(0));
        assertEq(quotedSeller, seller);
        assertEq(quotedListingHash, listingHash);
    }

    function test_PreviewSignedReceiptPurchase_WithIntegratorFeeReturnsExpectedValues() public {
        RevealReceiptStore feeStore = _deployStore(500);
        uint256 listingId = _createListingAs(feeStore, seller, listingHash);
        address integrator = address(0x1A7E);
        uint256 integratorFeeAmount = quotedAmount * 200 / 10_000;
        RevealReceiptStore.SignedReceiptQuote memory quote = _makeSignedReceiptQuoteWithIntegrator(
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
        assertEq(protocolFee, quotedAmount * 500 / 10_000);
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
        RevealReceiptStore.SignedReceiptQuote memory quote = _makeSignedReceiptQuoteWithIntegrator(
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
        RevealReceiptStore maxFeeStore = _deployStore(uint16(store.MAX_PROTOCOL_FEE_BPS()));
        uint256 listingId = _createListingAs(maxFeeStore, seller, listingHash);
        address integrator = address(0x1A7E);
        uint256 integratorFeeAmount = quotedAmount * maxFeeStore.MAX_INTEGRATOR_FEE_BPS() / 10_000;
        uint256 protocolFee = quotedAmount * maxFeeStore.MAX_PROTOCOL_FEE_BPS() / 10_000;
        RevealReceiptStore.SignedReceiptQuote memory quote = _makeSignedReceiptQuoteWithIntegrator(
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
        RevealReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, 0, uint64(block.timestamp + 1 days));

        vm.expectRevert(RevealReceiptStore.AmountOutOfBounds.selector);
        store.previewSignedReceiptPurchase(quote);
    }

    function test_PreviewSignedReceiptPurchase_AmountAboveMaxReverts() public {
        uint256 listingId = _createListingAsSeller();
        RevealReceiptStore.SignedReceiptQuote memory quote = _makeSignedReceiptQuote(
            listingId, buyer, purchaseRef, store.MAX_PURCHASE_AMOUNT() + 1, uint64(block.timestamp + 1 days)
        );

        vm.expectRevert(RevealReceiptStore.AmountOutOfBounds.selector);
        store.previewSignedReceiptPurchase(quote);
    }

    function test_PreviewSignedReceiptPurchase_ZeroPurchaseRefReverts() public {
        uint256 listingId = _createListingAsSeller();
        RevealReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, bytes32(0), quotedAmount, uint64(block.timestamp + 1 days));

        vm.expectRevert(RevealReceiptStore.InvalidPurchaseRef.selector);
        store.previewSignedReceiptPurchase(quote);
    }

    function test_PreviewSignedReceiptPurchase_ZeroMetadataHashReverts() public {
        uint256 listingId = _createListingAsSeller();
        RevealReceiptStore.SignedReceiptQuote memory quote =
            _makeSignedReceiptQuote(listingId, buyer, purchaseRef, quotedAmount, uint64(block.timestamp + 1 days));
        quote.metadataHash = bytes32(0);

        vm.expectRevert(RevealReceiptStore.InvalidParams.selector);
        store.previewSignedReceiptPurchase(quote);
    }

    function test_PreviewSignedReceiptPurchase_IntegratorRecipientWithoutFeeReverts() public {
        uint256 listingId = _createListingAsSeller();
        RevealReceiptStore.SignedReceiptQuote memory quote = _makeSignedReceiptQuoteWithIntegrator(
            listingId, buyer, purchaseRef, quotedAmount, address(0x1A7E), 0, uint64(block.timestamp + 1 days)
        );

        vm.expectRevert(RevealReceiptStore.InvalidParams.selector);
        store.previewSignedReceiptPurchase(quote);
    }

    function test_PreviewSignedReceiptPurchase_IntegratorFeeWithoutRecipientReverts() public {
        uint256 listingId = _createListingAsSeller();
        RevealReceiptStore.SignedReceiptQuote memory quote = _makeSignedReceiptQuoteWithIntegrator(
            listingId, buyer, purchaseRef, quotedAmount, address(0), 1, uint64(block.timestamp + 1 days)
        );

        vm.expectRevert(RevealReceiptStore.InvalidParams.selector);
        store.previewSignedReceiptPurchase(quote);
    }

    function test_PreviewSignedReceiptPurchase_IntegratorFeeTooHighReverts() public {
        uint256 listingId = _createListingAsSeller();
        uint256 integratorFeeAmount = quotedAmount * 1001 / 10_000;
        RevealReceiptStore.SignedReceiptQuote memory quote = _makeSignedReceiptQuoteWithIntegrator(
            listingId,
            buyer,
            purchaseRef,
            quotedAmount,
            address(0x1A7E),
            integratorFeeAmount,
            uint64(block.timestamp + 1 days)
        );

        vm.expectRevert(RevealReceiptStore.IntegratorFeeTooHigh.selector);
        store.previewSignedReceiptPurchase(quote);
    }

    function test_QuotePurchaseReceipt_ReturnsGrossFeeAndNet() public {
        RevealReceiptStore feeStore = _deployStore(500);
        uint256 listingId = _createListingAs(feeStore, seller, listingHash);

        (uint256 grossAmount, uint256 protocolFee, uint256 sellerNet, address quotedFeeRecipient) =
            feeStore.quotePurchaseReceipt(listingId);

        assertEq(grossAmount, unitPrice);
        assertEq(protocolFee, unitPrice * 500 / 10_000);
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

    function test_QuotePurchaseReceipt_ReturnsUpdatedPriceAfterPriceUpdate() public {
        RevealReceiptStore feeStore = _deployStore(500);
        uint256 listingId = _createListingAs(feeStore, seller, listingHash);

        vm.prank(seller);
        feeStore.setListingPrice(listingId, updatedUnitPrice);

        (uint256 grossAmount, uint256 protocolFee, uint256 sellerNet, address quotedFeeRecipient) =
            feeStore.quotePurchaseReceipt(listingId);

        assertEq(grossAmount, updatedUnitPrice);
        assertEq(protocolFee, updatedUnitPrice * 500 / 10_000);
        assertEq(sellerNet, updatedUnitPrice - protocolFee);
        assertEq(quotedFeeRecipient, feeRecipient);
    }

    function test_GetListingAndReceipt_NotFoundRevert() public {
        vm.expectRevert(RevealReceiptStore.ListingNotFound.selector);
        store.getListing(999);

        vm.expectRevert(RevealReceiptStore.ReceiptNotFound.selector);
        store.getReceipt(999);
    }

    function test_GetReceipt_UsesSellerSentinelForExistence() public {
        uint256 listingId = _createListingAsSeller();
        uint256 receiptId = _purchaseReceiptAs(listingId, buyer, purchaseRef);

        RevealReceiptStore.Receipt memory receipt = store.getReceipt(receiptId);
        assertEq(receipt.listingId, listingId);
        assertEq(receipt.seller, seller);
        assertEq(receipt.buyer, buyer);

        (
            uint256 storedListingId,
            address storedSeller,
            address storedBuyer,
            uint256 storedAmount,
            bytes32 storedRef,
            uint64 issuedAt
        ) = store.receipts(999);
        assertEq(storedListingId, 0);
        assertEq(storedSeller, address(0));
        assertEq(storedBuyer, address(0));
        assertEq(storedAmount, 0);
        assertEq(storedRef, bytes32(0));
        assertEq(issuedAt, 0);

        vm.expectRevert(RevealReceiptStore.ReceiptNotFound.selector);
        store.getReceipt(999);
    }

    function test_ReceiptPurchased_EventIndexesBuyerAndEmitsPurchaseRefInData() public {
        uint256 listingId = _createListingAsSeller();

        vm.recordLogs();
        uint256 receiptId = _purchaseReceiptAs(listingId, buyer, purchaseRef);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        bytes32 receiptPurchasedTopic0 =
            keccak256("ReceiptPurchased(uint256,address,address,uint256,bytes32,uint256,bytes32)");
        bool found;

        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].topics.length == 4 && entries[i].topics[0] == receiptPurchasedTopic0) {
                found = true;
                assertEq(entries[i].topics[1], bytes32(receiptId));
                assertEq(entries[i].topics[2], bytes32(uint256(uint160(seller))));
                assertEq(entries[i].topics[3], bytes32(uint256(uint160(buyer))));

                (uint256 loggedListingId, bytes32 loggedPurchaseRef, uint256 loggedAmount, bytes32 loggedMetadataHash) =
                    abi.decode(entries[i].data, (uint256, bytes32, uint256, bytes32));

                assertEq(loggedListingId, listingId);
                assertEq(loggedPurchaseRef, purchaseRef);
                assertEq(loggedAmount, unitPrice);
                assertEq(loggedMetadataHash, bytes32(0));
                break;
            }
        }

        assertTrue(found);
    }
}
