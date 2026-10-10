// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {NotaReceiptStore} from "../src/NotaReceiptStore.sol";
import {PurchaseRefRegistry} from "../src/PurchaseRefRegistry.sol";

/// @title Arbitrum One v2 smoke test
/// @notice Creates a quote-only listing on the Arbitrum One v2 store, buys one $0.10 data query
///         with a distinct buyer, and checks that the deployed contract rejects a replayed
///         purchaseRef and a buyer-bound quote submitted from a different wallet.
///
/// Required environment:
///   export ARBITRUM_RPC_URL="https://..."
///   export NOTA_RECEIPT_STORE="0x..."     # Arbitrum One v2 store (deployments/arbitrum-one.json)
///   export PURCHASE_REF_REGISTRY="0x..."  # its own v2 registry, not the v1 one
///   export SELLER_PRIVATE_KEY="0x..."     # Arbitrum ETH for listing creation
///   export BUYER_PRIVATE_KEY="0x..."      # Arbitrum ETH plus at least 0.10 native USDC
///   export PURCHASE_REF_NONCE="0x$(openssl rand -hex 32)" # generate once for this purchase
///
/// Dry run (full fork simulation; omitting `--broadcast` guarantees nothing is sent):
///   forge script script/DemoPurchaseArbitrumOne.s.sol:DemoPurchaseArbitrumOne \
///     --rpc-url "$ARBITRUM_RPC_URL" --slow -vvvv
///
/// Broadcast to Arbitrum One:
///   forge script script/DemoPurchaseArbitrumOne.s.sol:DemoPurchaseArbitrumOne \
///     --rpc-url "$ARBITRUM_RPC_URL" --broadcast --slow -vvvv
///
/// Only three transactions are broadcast: createListing (seller), approve and
/// purchaseSignedReceipt (buyer). The two negative checks run in the local simulation against
/// the deployed bytecode and are never sent: a reverting transaction would only burn gas, and the
/// simulation already proves the deployed contract returns the expected custom error.
///
/// @dev Writes the JCS-canonical metadata preimage to `script/demo-metadata-arbitrum-one.json`,
///      never to `script/demo-metadata.json`, whose committed copy matches Base receipt #1.
///      After a successful broadcast, commit that file so a public reader can reproduce the
///      receipt's metadataHash with `cast keccak "$(jq -cS . script/demo-metadata-arbitrum-one.json)"`.
contract DemoPurchaseArbitrumOne is Script {
    using Strings for address;
    using Strings for uint256;

    uint256 internal constant ARBITRUM_ONE_CHAIN_ID = 42161;
    uint256 internal constant AMOUNT = 100_000; // 0.10 USDC (6 decimals)
    uint64 internal constant QUOTE_TTL = 1 hours;

    address internal constant USDC_ADDRESS = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    /// @dev June 2026 v1 registry. The v2 store must not point at it.
    address internal constant V1_REGISTRY_ADDRESS = 0x6c55B0211cCF687F1505f03a7436302e59564446;

    string internal constant RAW_PURCHASE_REF = "nota_demo_arbitrum_one_fee_history_query_v1";
    string internal constant LISTING_PATH = "/script/demo-listing-arbitrum-one.json";
    string internal constant METADATA_PATH = "/script/demo-metadata-arbitrum-one.json";

    // See DemoPurchase.s.sol: Checkout Metadata v1's protocol version, independent of the
    // EIP-712 signing-domain version.
    string internal constant CHECKOUT_METADATA_PROTOCOL_VERSION = "1";
    string internal constant EIP712_DOMAIN_NAME = "NotaReceiptStore";
    string internal constant EIP712_DOMAIN_VERSION = "2";

    // Illustrative, seller-attested ERC-8004-shaped agent id; not resolved on-chain.
    bytes32 internal constant ILLUSTRATIVE_AGENT_ID = bytes32(uint256(80_040_042));

    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant SIGNED_RECEIPT_QUOTE_TYPEHASH = keccak256(
        "SignedReceiptQuote(uint256 listingId,address seller,address buyer,bytes32 purchaseRef,uint256 amount,bytes32 metadataHash,bytes32 agentId,address settlementToken,address purchaseRefRegistry,address integratorFeeRecipient,uint256 integratorFeeAmount,uint64 issuedAt,uint64 expiresAt)"
    );
    bytes32 internal constant RECEIPT_PURCHASED_V2_TOPIC =
        keccak256("ReceiptPurchasedV2(uint256,address,address,uint256,bytes32,uint256,bytes32,bytes32)");

    address internal storeAddress;
    address internal registryAddress;

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
        storeAddress = vm.envAddress("NOTA_RECEIPT_STORE");
        registryAddress = vm.envAddress("PURCHASE_REF_REGISTRY");
        NotaReceiptStore store = NotaReceiptStore(storeAddress);
        IERC20 usdc = IERC20(USDC_ADDRESS);
        DemoRun memory demo = _prepareRun(store, usdc);

        _logPreBroadcast(demo);

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

        NotaReceiptStore.SignedReceiptPurchaseValidation memory validation =
            store.validateSignedReceiptPurchase(demo.quote, sellerSignature, demo.buyer, address(0));
        require(validation.seller == demo.seller, "validated seller mismatch");
        require(validation.grossAmount == AMOUNT, "validated amount mismatch");
        require(validation.verifiedSigner == demo.seller, "validated signer mismatch");
        require(validation.protocolFee == 0, "Arbitrum One v2 must charge no protocol fee");

        // Negative check 1 (simulation only): the quote is bound to `buyer`, so any other wallet
        // must be refused before funds move. Run while the purchaseRef is still unconsumed so the
        // only possible failure is the buyer binding.
        address otherWallet = vm.addr(uint256(keccak256("nota.demo.arbitrum-one.other-wallet")));
        require(otherWallet != demo.buyer && otherWallet != demo.seller, "other wallet collides");
        _expectPurchaseRevert(
            store, demo.quote, sellerSignature, otherWallet, NotaReceiptStore.QuoteBuyerMismatch.selector
        );

        vm.startBroadcast(demo.buyerPrivateKey);
        require(usdc.approve(storeAddress, AMOUNT), "USDC approve returned false");
        vm.stopBroadcast();

        vm.recordLogs();
        vm.startBroadcast(demo.buyerPrivateKey);
        uint256 receiptId = store.purchaseSignedReceipt(demo.quote, sellerSignature, address(0));
        vm.stopBroadcast();

        DecodedReceipt memory receipt = _receiptFromSimulation(vm.getRecordedLogs());
        _assertReceipt(receipt, receiptId, demo.quote, demo.seller, demo.buyer);
        require(PurchaseRefRegistry(registryAddress).isConsumed(demo.quote.purchaseRef), "purchaseRef not consumed");

        // Negative check 2 (simulation only): the same buyer resubmitting the same quote must hit
        // the registry-backed replay guard.
        _expectPurchaseRevert(
            store, demo.quote, sellerSignature, demo.buyer, NotaReceiptStore.PurchaseRefAlreadyUsed.selector
        );

        console2.log("=== Simulated ReceiptPurchasedV2 (same calldata queued for broadcast) ===");
        _logReceipt(receipt);
        console2.log("Replay of purchaseRef reverted with PurchaseRefAlreadyUsed (simulated)");
        console2.log("Quote from a different wallet reverted with QuoteBuyerMismatch (simulated)");
    }

    function _expectPurchaseRevert(
        NotaReceiptStore store,
        NotaReceiptStore.SignedReceiptQuote memory quote,
        bytes memory sellerSignature,
        address caller,
        bytes4 expectedSelector
    ) internal {
        vm.prank(caller);
        try store.purchaseSignedReceipt(quote, sellerSignature, address(0)) {
            revert("purchase unexpectedly succeeded");
        } catch (bytes memory reason) {
            require(keccak256(reason) == keccak256(abi.encodePacked(expectedSelector)), "unexpected revert reason");
        }
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
        demo.listingHash = _hashCanonicalJsonFile(LISTING_PATH);
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
        string memory metadataPath = string.concat(vm.projectRoot(), METADATA_PATH);
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

    function _preflight(NotaReceiptStore store, IERC20 usdc, address seller, address buyer) internal view {
        require(block.chainid == ARBITRUM_ONE_CHAIN_ID, "DemoPurchaseArbitrumOne only runs on Arbitrum One");
        require(registryAddress != V1_REGISTRY_ADDRESS, "PURCHASE_REF_REGISTRY is the v1 registry");
        require(storeAddress.code.length != 0, "NotaReceiptStore has no code");
        require(registryAddress.code.length != 0, "PurchaseRefRegistry has no code");
        require(USDC_ADDRESS.code.length != 0, "USDC has no code");
        require(address(store.SETTLEMENT_TOKEN()) == USDC_ADDRESS, "store settlement token mismatch");
        require(address(store.PURCHASE_REF_REGISTRY()) == registryAddress, "store registry mismatch");
        require(store.PROTOCOL_FEE_BPS() == 0, "store protocol fee is not zero");
        require(store.FEE_RECIPIENT() == address(0), "store has a fee recipient");
        require(
            keccak256(bytes(store.EIP712_NAME())) == keccak256(bytes(EIP712_DOMAIN_NAME)), "store EIP-712 name mismatch"
        );
        require(
            keccak256(bytes(store.EIP712_VERSION())) == keccak256(bytes(EIP712_DOMAIN_VERSION)),
            "store EIP-712 version mismatch"
        );
        require(
            PurchaseRefRegistry(registryAddress).authorizedConsumers(storeAddress),
            "store is not an authorized purchaseRef consumer"
        );
        require(!store.listingCreationPaused(), "listing creation is paused");
        require(!store.purchasesPaused(), "purchases are paused");
        require(usdc.balanceOf(buyer) >= AMOUNT, "buyer needs at least 0.10 USDC");
        require(seller.balance != 0, "seller needs Arbitrum ETH for gas");
        require(buyer.balance != 0, "buyer needs Arbitrum ETH for gas");
    }

    function _hashCanonicalJsonFile(string memory relativePath) internal view returns (bytes32) {
        // forge-lint: disable-next-line(unsafe-cheatcode)
        bytes memory canonical = bytes(vm.readFile(string.concat(vm.projectRoot(), relativePath)));
        // Strip only a trailing transport newline (LF, then CR); JCS output has none.
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

    function _hashPurchaseRef(address seller, string memory rawPurchaseRef, bytes32 purchaseRefNonce)
        internal
        pure
        returns (bytes32)
    {
        // Exact preimage used by NotaReceiptStore.hashPurchaseRef.
        return keccak256(
            abi.encode(
                "nota.purchaseRef.receipt.v1",
                ARBITRUM_ONE_CHAIN_ID,
                USDC_ADDRESS,
                seller,
                rawPurchaseRef,
                purchaseRefNonce
            )
        );
    }

    function _canonicalMetadata(MetadataFields memory fields) internal view returns (string memory) {
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
            '{"checkout":{"description":"One structured Arbitrum One eth_feeHistory query for an autonomous agent",',
            '"externalOrderId":"nota-demo-arbitrum-one-fee-history-',
            listingId.toString(),
            '","kind":"x402:agent_request","title":"Arbitrum One fee history data query"}'
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

    function _canonicalProtocol() internal view returns (string memory) {
        return string.concat(
            ',"protocol":{"chainId":42161,"name":"Nota","receiptStore":"',
            storeAddress.toChecksumHexString(),
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
        view
        returns (bytes32)
    {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes(EIP712_DOMAIN_NAME)),
                keccak256(bytes(EIP712_DOMAIN_VERSION)),
                ARBITRUM_ONE_CHAIN_ID,
                storeAddress
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
                    registryAddress,
                    quote.integratorFeeRecipient,
                    quote.integratorFeeAmount,
                    quote.issuedAt,
                    quote.expiresAt
                )
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function _receiptFromSimulation(Vm.Log[] memory entries) internal view returns (DecodedReceipt memory) {
        for (uint256 i = entries.length; i > 0; --i) {
            Vm.Log memory entry = entries[i - 1];
            if (
                entry.emitter == storeAddress && entry.topics.length == 4
                    && entry.topics[0] == RECEIPT_PURCHASED_V2_TOPIC
            ) {
                return _decodeReceipt(entry.topics, entry.data);
            }
        }
        revert("ReceiptPurchasedV2 not found in simulation logs");
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

    function _logPreBroadcast(DemoRun memory demo) internal view {
        console2.log("=== Arbitrum One demo purchase pre-broadcast review ===");
        console2.log("store", storeAddress);
        console2.log("registry", registryAddress);
        console2.log("seller", demo.seller);
        console2.log("buyer", demo.buyer);
        console2.log("listingId", demo.listingId);
        _logBytes32("listingHash", demo.listingHash);
        _logBytes32("metadataHash", demo.quote.metadataHash);
        _logBytes32("purchaseRef", demo.quote.purchaseRef);
        _logBytes32("EIP-712 digest", demo.expectedDigest);
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
