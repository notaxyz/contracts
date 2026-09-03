// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {NotaReceiptStore} from "../src/NotaReceiptStore.sol";
import {PurchaseRefRegistry} from "../src/PurchaseRefRegistry.sol";

/// @title Base mainnet ReceiptPurchasedV2 demo
/// @notice Creates a quote-only listing and buys one $0.10 data query with a distinct buyer.
///
/// Required environment:
///   export BASE_RPC_URL="https://..."
///   export SELLER_PRIVATE_KEY="0x..."  # Base ETH for listing creation
///   export BUYER_PRIVATE_KEY="0x..."   # Base ETH plus at least 0.10 USDC
///   export PURCHASE_REF_NONCE="0x$(openssl rand -hex 32)" # generate once for this purchase
///
/// Dry run (full fork simulation; omitting `--broadcast` guarantees nothing is sent):
///   forge script script/DemoPurchase.s.sol:DemoPurchase --rpc-url "$BASE_RPC_URL" --slow -vvvv
///
/// Broadcast to Base mainnet:
///   forge script script/DemoPurchase.s.sol:DemoPurchase --rpc-url "$BASE_RPC_URL" --broadcast --slow -vvvv
///
/// Print the confirmed purchase tx hash and decode its actual ReceiptPurchasedV2 log:
///   forge script script/DemoPurchase.s.sol:DemoPurchase --sig "report()" --rpc-url "$BASE_RPC_URL" -vvvv
///
/// Independently reproduce the committed metadata hash (jq emits one canonical line):
///   cast keccak "$(jq -cS . script/demo-metadata.json)"
///
/// @dev Each run materializes `script/demo-metadata.json` as the exact JCS-canonical metadata
///      preimage for that run. After a successful broadcast, commit that file so a public reader
///      can reproduce the receipt's metadataHash. `script/demo-listing.json` is a separate
///      canonical commitment because Checkout Metadata v1 embeds listingHash; using one document
///      for both hashes would be a circular commitment.
contract DemoPurchase is Script {
    using Strings for address;
    using Strings for uint256;

    uint256 internal constant BASE_MAINNET_CHAIN_ID = 8453;
    uint256 internal constant AMOUNT = 100_000; // 0.10 USDC (6 decimals)
    uint64 internal constant QUOTE_TTL = 1 hours;

    address internal constant STORE_ADDRESS = 0xf6062F3F52D3E19cb9cc3e027491a5c11D101F88;
    address internal constant REGISTRY_ADDRESS = 0x9AaFfA5787ca332a40B9C98E3e5323A97F96D991;
    address internal constant USDC_ADDRESS = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    string internal constant RAW_PURCHASE_REF = "nota_demo_base_fee_history_query_v1";

    // Checkout Metadata v1's protocol version, matching merchant-api MetadataProtocol.version and
    // the `nota.checkout.metadata.v1` example in this repository. It is intentionally independent
    // of NotaReceiptStore's EIP-712 signing-domain version.
    string internal constant CHECKOUT_METADATA_PROTOCOL_VERSION = "1";
    string internal constant EIP712_DOMAIN_NAME = "NotaReceiptStore";
    string internal constant EIP712_DOMAIN_VERSION = "2";

    // ERC-8004 agent IDs are uint256 ERC-721 token IDs. This illustrative tokenId-shaped value is
    // seller-attested only: NotaReceiptStore does not resolve it against an Identity Registry.
    bytes32 internal constant ILLUSTRATIVE_AGENT_ID = bytes32(uint256(80_040_042));

    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant SIGNED_RECEIPT_QUOTE_TYPEHASH = keccak256(
        "SignedReceiptQuote(uint256 listingId,address seller,address buyer,bytes32 purchaseRef,uint256 amount,bytes32 metadataHash,bytes32 agentId,address settlementToken,address purchaseRefRegistry,address integratorFeeRecipient,uint256 integratorFeeAmount,uint64 issuedAt,uint64 expiresAt)"
    );
    bytes32 internal constant RECEIPT_PURCHASED_V2_TOPIC =
        keccak256("ReceiptPurchasedV2(uint256,address,address,uint256,bytes32,uint256,bytes32,bytes32)");

    struct DecodedReceipt {
        uint256 receiptId;
        address seller;
        address buyer;
        uint256 listingId;
        bytes32 purchaseRef;
        uint256 amount;
        bytes32 metadataHash;
        bytes32 agentId;
    }

    struct DemoRun {
        uint256 sellerPrivateKey;
        uint256 buyerPrivateKey;
        address seller;
        address buyer;
        uint256 listingId;
        bytes32 listingHash;
        bytes32 purchaseRefNonce;
        bytes32 expectedDigest;
        NotaReceiptStore.SignedReceiptQuote quote;
    }

    struct MetadataFields {
        address seller;
        address buyer;
        uint256 listingId;
        bytes32 listingHash;
        bytes32 purchaseRef;
        uint64 issuedAt;
        uint64 expiresAt;
    }

    function run() external {
        NotaReceiptStore store = NotaReceiptStore(STORE_ADDRESS);
        IERC20 usdc = IERC20(USDC_ADDRESS);
        DemoRun memory demo = _prepareRun(store, usdc);

        // Compute locally first so every value can be reviewed before any transaction is marked
        // for broadcast. After listing creation, this digest is checked byte-for-byte against the
        // deployed contract's own hashSignedReceiptQuote result, which is the value vm.sign uses.
        _logPreBroadcast(
            demo.seller,
            demo.buyer,
            demo.listingId,
            demo.listingHash,
            demo.quote.metadataHash,
            demo.quote.purchaseRef,
            demo.expectedDigest
        );

        vm.startBroadcast(demo.sellerPrivateKey);
        uint256 createdListingId =
            store.createListing(demo.listingHash, 0, NotaReceiptStore.ListingMode.SignedQuoteOnly);
        vm.stopBroadcast();
        require(createdListingId == demo.listingId, "nextListingId changed during execution");

        require(
            store.hashPurchaseRef(demo.seller, demo.listingId, RAW_PURCHASE_REF, demo.purchaseRefNonce)
                == demo.quote.purchaseRef,
            "purchaseRef does not match deployed helper"
        );
        bytes32 contractDigest = store.hashSignedReceiptQuote(demo.quote);
        require(contractDigest == demo.expectedDigest, "local digest does not match deployed contract");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(demo.sellerPrivateKey, contractDigest);
        bytes memory sellerSignature = abi.encodePacked(r, s, v);

        // This view call exercises the contract's full quote/signature validation before the buyer
        // spends anything. The buyer is passed explicitly because the quote is buyer-bound.
        NotaReceiptStore.SignedReceiptPurchaseValidation memory validation =
            store.validateSignedReceiptPurchase(demo.quote, sellerSignature, demo.buyer, address(0));
        require(validation.seller == demo.seller, "validated seller mismatch");
        require(validation.grossAmount == AMOUNT, "validated amount mismatch");
        require(validation.verifiedSigner == demo.seller, "validated signer mismatch");

        vm.startBroadcast(demo.buyerPrivateKey);
        require(usdc.approve(STORE_ADDRESS, AMOUNT), "USDC approve returned false");
        vm.stopBroadcast();

        vm.recordLogs();
        vm.startBroadcast(demo.buyerPrivateKey);
        uint256 receiptId = store.purchaseSignedReceipt(demo.quote, sellerSignature, address(0));
        vm.stopBroadcast();

        DecodedReceipt memory receipt = _receiptFromSimulation(vm.getRecordedLogs());
        _assertReceipt(receipt, receiptId, demo.quote, demo.seller, demo.buyer);

        console2.log("=== Simulated ReceiptPurchasedV2 (same calldata queued for broadcast) ===");
        _logReceipt(receipt);
        console2.log("Foundry prints every transaction hash in the broadcast summary below.");
        console2.log("After confirmation, run report() from the header for the purchase tx hash and mined log.");
    }

    function _prepareRun(NotaReceiptStore store, IERC20 usdc) internal returns (DemoRun memory demo) {
        demo.sellerPrivateKey = vm.envUint("SELLER_PRIVATE_KEY");
        demo.buyerPrivateKey = vm.envUint("BUYER_PRIVATE_KEY");
        require(demo.sellerPrivateKey != 0, "SELLER_PRIVATE_KEY is zero");
        require(demo.buyerPrivateKey != 0, "BUYER_PRIVATE_KEY is zero");

        demo.seller = vm.addr(demo.sellerPrivateKey);
        demo.buyer = vm.addr(demo.buyerPrivateKey);
        require(demo.seller != demo.buyer, "seller and buyer must be distinct");
        _preflight(store, usdc, demo.seller, demo.buyer);

        demo.listingId = store.nextListingId();
        demo.listingHash = _hashCanonicalJsonFile("/script/demo-listing.json");
        demo.purchaseRefNonce = vm.envBytes32("PURCHASE_REF_NONCE");
        require(demo.purchaseRefNonce != bytes32(0), "PURCHASE_REF_NONCE is zero");
        bytes32 purchaseRef = _hashPurchaseRef(demo.seller, RAW_PURCHASE_REF, demo.purchaseRefNonce);

        require(block.timestamp <= type(uint64).max - QUOTE_TTL, "timestamp does not fit quote fields");
        uint64 issuedAt = uint64(block.timestamp);
        uint64 expiresAt = issuedAt + QUOTE_TTL;

        string memory canonicalMetadata = _canonicalMetadata(
            MetadataFields({
                seller: demo.seller,
                buyer: demo.buyer,
                listingId: demo.listingId,
                listingHash: demo.listingHash,
                purchaseRef: purchaseRef,
                issuedAt: issuedAt,
                expiresAt: expiresAt
            })
        );
        string memory metadataPath = string.concat(vm.projectRoot(), "/script/demo-metadata.json");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.writeFile(metadataPath, canonicalMetadata);
        // forge-lint: disable-next-line(unsafe-cheatcode)
        bytes32 metadataHash = keccak256(bytes(vm.readFile(metadataPath)));
        require(metadataHash == keccak256(bytes(canonicalMetadata)), "metadata file changed while materializing");

        demo.quote = NotaReceiptStore.SignedReceiptQuote({
            listingId: demo.listingId,
            buyer: demo.buyer,
            purchaseRef: purchaseRef,
            amount: AMOUNT,
            metadataHash: metadataHash,
            agentId: ILLUSTRATIVE_AGENT_ID,
            integratorFeeRecipient: address(0),
            integratorFeeAmount: 0,
            issuedAt: issuedAt,
            expiresAt: expiresAt
        });
        demo.expectedDigest = _expectedDigest(demo.quote, demo.seller);
    }

    /// @notice Reports from the confirmed `run-latest.json` generated by `forge script --broadcast`.
    /// @dev Kept separate because transaction hashes and mined receipts do not exist until after
    ///      the Solidity script finishes and Foundry broadcasts its queued transactions.
    function report() external view {
        string memory path = string.concat(vm.projectRoot(), "/broadcast/DemoPurchase.s.sol/8453/run-latest.json");
        require(vm.exists(path), "broadcast receipt not found; run the --broadcast command first");

        Receipt[] memory receipts = readReceipts(path);
        for (uint256 i = receipts.length; i > 0; --i) {
            Receipt memory mined = receipts[i - 1];
            for (uint256 j = mined.logs.length; j > 0; --j) {
                ReceiptLog memory entry = mined.logs[j - 1];
                if (!_isReceiptLog(entry.logAddress, entry.topics)) continue;

                require(mined.status == 1, "purchase transaction failed");
                DecodedReceipt memory receipt = _decodeReceipt(entry.topics, entry.data);
                _assertConfirmedReceipt(receipt);
                console2.log("=== Confirmed Base mainnet purchase ===");
                _logBytes32("transactionHash", mined.transactionHash);
                console2.log("blockNumber", mined.blockNumber);
                _logReceipt(receipt);
                console2.log("metadata and listing documents verified", true);
                return;
            }
        }

        revert("ReceiptPurchasedV2 not found in latest broadcast receipts");
    }

    function _preflight(NotaReceiptStore store, IERC20 usdc, address seller, address buyer) internal view {
        require(block.chainid == BASE_MAINNET_CHAIN_ID, "DemoPurchase only runs on Base mainnet");
        require(STORE_ADDRESS.code.length != 0, "NotaReceiptStore has no code");
        require(REGISTRY_ADDRESS.code.length != 0, "PurchaseRefRegistry has no code");
        require(USDC_ADDRESS.code.length != 0, "USDC has no code");
        require(address(store.SETTLEMENT_TOKEN()) == USDC_ADDRESS, "store settlement token mismatch");
        require(address(store.PURCHASE_REF_REGISTRY()) == REGISTRY_ADDRESS, "store registry mismatch");
        require(
            keccak256(bytes(store.EIP712_NAME())) == keccak256(bytes(EIP712_DOMAIN_NAME)), "store EIP-712 name mismatch"
        );
        require(
            keccak256(bytes(store.EIP712_VERSION())) == keccak256(bytes(EIP712_DOMAIN_VERSION)),
            "store EIP-712 version mismatch"
        );
        require(
            PurchaseRefRegistry(REGISTRY_ADDRESS).authorizedConsumers(STORE_ADDRESS),
            "store is not an authorized purchaseRef consumer"
        );
        require(!store.listingCreationPaused(), "listing creation is paused");
        require(!store.purchasesPaused(), "purchases are paused");
        require(usdc.balanceOf(buyer) >= AMOUNT, "buyer needs at least 0.10 USDC");
        require(seller.balance != 0, "seller needs Base ETH for gas");
        require(buyer.balance != 0, "buyer needs Base ETH for gas");
    }

    function _hashCanonicalJsonFile(string memory relativePath) internal view returns (bytes32) {
        // forge-lint: disable-next-line(unsafe-cheatcode)
        bytes memory canonical = bytes(vm.readFile(string.concat(vm.projectRoot(), relativePath)));
        // Editors conventionally retain a final LF (or CRLF), while RFC 8785 serialization does
        // not. Strip only that transport newline; every other byte is already pinned in JCS order.
        if (canonical.length != 0 && canonical[canonical.length - 1] == 0x0a) {
            assembly ("memory-safe") {
                mstore(canonical, sub(mload(canonical), 1))
            }
        }
        if (canonical.length != 0 && canonical[canonical.length - 1] == 0x0d) {
            assembly ("memory-safe") {
                mstore(canonical, sub(mload(canonical), 1))
            }
        }
        require(canonical.length >= 2 && canonical[0] == "{" && canonical[canonical.length - 1] == "}", "bad JSON");
        return keccak256(canonical);
    }

    function _assertConfirmedReceipt(DecodedReceipt memory receipt) internal view {
        require(receipt.amount == AMOUNT, "confirmed amount mismatch");
        require(receipt.agentId == ILLUSTRATIVE_AGENT_ID, "confirmed agentId mismatch");
        require(
            receipt.metadataHash == _hashCanonicalJsonFile("/script/demo-metadata.json"),
            "confirmed metadataHash does not match demo-metadata.json"
        );

        NotaReceiptStore.Listing memory listing = NotaReceiptStore(STORE_ADDRESS).getListing(receipt.listingId);
        require(listing.seller == receipt.seller, "confirmed listing seller mismatch");
        require(
            listing.listingHash == _hashCanonicalJsonFile("/script/demo-listing.json"),
            "confirmed listingHash does not match demo-listing.json"
        );
        require(listing.mode == NotaReceiptStore.ListingMode.SignedQuoteOnly, "confirmed listing mode mismatch");
        require(
            PurchaseRefRegistry(REGISTRY_ADDRESS).consumedBy(receipt.purchaseRef) == STORE_ADDRESS,
            "confirmed purchaseRef was not consumed by store"
        );
    }

    function _hashPurchaseRef(address seller, string memory rawPurchaseRef, bytes32 purchaseRefNonce)
        internal
        pure
        returns (bytes32)
    {
        // Exact preimage used by NotaReceiptStore.hashPurchaseRef. listingId is deliberately not
        // part of the protocol hash; the raw demo reference includes the run's purpose instead.
        return keccak256(
            abi.encode(
                "nota.purchaseRef.receipt.v1",
                BASE_MAINNET_CHAIN_ID,
                USDC_ADDRESS,
                seller,
                rawPurchaseRef,
                purchaseRefNonce
            )
        );
    }

    function _canonicalMetadata(MetadataFields memory fields) internal pure returns (string memory) {
        // Keys at every object level are emitted in UTF-16 lexicographic order and all values are
        // already in their JCS form. Addresses are EIP-55-checksummed to match merchant-api.
        return string.concat(
            _canonicalCheckout(fields.listingId),
            _canonicalListing(fields.listingId, fields.listingHash),
            _canonicalProtocol(),
            _canonicalQuote(fields.buyer, fields.purchaseRef, fields.issuedAt, fields.expiresAt),
            ',"schema":"nota.checkout.metadata.v1","seller":"',
            fields.seller.toChecksumHexString(),
            '"}'
        );
    }

    function _canonicalCheckout(uint256 listingId) internal pure returns (string memory) {
        return string.concat(
            '{"checkout":{"description":"One structured Base mainnet eth_feeHistory query for an autonomous agent",',
            '"externalOrderId":"nota-demo-base-fee-history-',
            listingId.toString(),
            '","kind":"x402:agent_request","title":"Base fee history data query"}'
        );
    }

    function _canonicalListing(uint256 listingId, bytes32 listingHash) internal pure returns (string memory) {
        return string.concat(
            ',"listing":{"listingHash":"',
            uint256(listingHash).toHexString(32),
            '","listingId":"',
            listingId.toString(),
            '"}'
        );
    }

    function _canonicalProtocol() internal pure returns (string memory) {
        return string.concat(
            ',"protocol":{"chainId":8453,"name":"Nota","receiptStore":"',
            STORE_ADDRESS.toChecksumHexString(),
            '","settlementToken":"',
            USDC_ADDRESS.toChecksumHexString(),
            '","version":"',
            CHECKOUT_METADATA_PROTOCOL_VERSION,
            '"}'
        );
    }

    function _canonicalQuote(address buyer, bytes32 purchaseRef, uint64 issuedAt, uint64 expiresAt)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            ',"quote":{"amount":"100000","buyer":"',
            buyer.toChecksumHexString(),
            '","currency":"USDC","decimals":6,"expiresAt":',
            uint256(expiresAt).toString(),
            ',"issuedAt":',
            uint256(issuedAt).toString(),
            ',"purchaseRef":"',
            uint256(purchaseRef).toHexString(32),
            '"}'
        );
    }

    function _expectedDigest(NotaReceiptStore.SignedReceiptQuote memory quote, address seller)
        internal
        pure
        returns (bytes32)
    {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes(EIP712_DOMAIN_NAME)),
                keccak256(bytes(EIP712_DOMAIN_VERSION)),
                BASE_MAINNET_CHAIN_ID,
                STORE_ADDRESS
            )
        );
        bytes32 structHash = keccak256(
            bytes.concat(
                abi.encode(
                    SIGNED_RECEIPT_QUOTE_TYPEHASH,
                    quote.listingId,
                    seller,
                    quote.buyer,
                    quote.purchaseRef,
                    quote.amount,
                    quote.metadataHash,
                    quote.agentId
                ),
                abi.encode(
                    USDC_ADDRESS,
                    REGISTRY_ADDRESS,
                    quote.integratorFeeRecipient,
                    quote.integratorFeeAmount,
                    quote.issuedAt,
                    quote.expiresAt
                )
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function _receiptFromSimulation(Vm.Log[] memory entries) internal pure returns (DecodedReceipt memory) {
        for (uint256 i = entries.length; i > 0; --i) {
            Vm.Log memory entry = entries[i - 1];
            if (_isReceiptLog(entry.emitter, entry.topics)) {
                return _decodeReceipt(entry.topics, entry.data);
            }
        }
        revert("ReceiptPurchasedV2 not found in simulation logs");
    }

    function _isReceiptLog(address emitter, bytes32[] memory topics) internal pure returns (bool) {
        return emitter == STORE_ADDRESS && topics.length == 4 && topics[0] == RECEIPT_PURCHASED_V2_TOPIC;
    }

    function _decodeReceipt(bytes32[] memory topics, bytes memory data)
        internal
        pure
        returns (DecodedReceipt memory receipt)
    {
        receipt.seller = address(uint160(uint256(topics[1])));
        receipt.buyer = address(uint160(uint256(topics[2])));
        receipt.purchaseRef = topics[3];
        (receipt.receiptId, receipt.listingId, receipt.amount, receipt.metadataHash, receipt.agentId) =
            abi.decode(data, (uint256, uint256, uint256, bytes32, bytes32));
    }

    function _assertReceipt(
        DecodedReceipt memory receipt,
        uint256 receiptId,
        NotaReceiptStore.SignedReceiptQuote memory quote,
        address seller,
        address buyer
    ) internal pure {
        require(receipt.receiptId == receiptId, "receiptId mismatch");
        require(receipt.seller == seller, "receipt seller mismatch");
        require(receipt.buyer == buyer, "receipt buyer mismatch");
        require(receipt.listingId == quote.listingId, "receipt listingId mismatch");
        require(receipt.purchaseRef == quote.purchaseRef, "receipt purchaseRef mismatch");
        require(receipt.amount == quote.amount, "receipt amount mismatch");
        require(receipt.metadataHash == quote.metadataHash, "receipt metadataHash mismatch");
        require(receipt.agentId == quote.agentId, "receipt agentId mismatch");
    }

    function _logPreBroadcast(
        address seller,
        address buyer,
        uint256 listingId,
        bytes32 listingHash,
        bytes32 metadataHash,
        bytes32 purchaseRef,
        bytes32 digest
    ) internal pure {
        console2.log("=== Demo purchase pre-broadcast review ===");
        console2.log("seller", seller);
        console2.log("buyer", buyer);
        console2.log("listingId", listingId);
        _logBytes32("listingHash", listingHash);
        _logBytes32("metadataHash", metadataHash);
        _logBytes32("purchaseRef", purchaseRef);
        _logBytes32("EIP-712 digest", digest);
        console2.log("quote amount (USDC base units)", AMOUNT);
        console2.log("quote amount (USDC)", "0.10");
    }

    function _logReceipt(DecodedReceipt memory receipt) internal pure {
        console2.log("receiptId", receipt.receiptId);
        console2.log("seller", receipt.seller);
        console2.log("buyer", receipt.buyer);
        console2.log("listingId", receipt.listingId);
        _logBytes32("purchaseRef", receipt.purchaseRef);
        console2.log("amount", receipt.amount);
        _logBytes32("metadataHash", receipt.metadataHash);
        _logBytes32("agentId", receipt.agentId);
    }

    function _logBytes32(string memory label, bytes32 value) internal pure {
        console2.log(label);
        console2.logBytes32(value);
    }
}
