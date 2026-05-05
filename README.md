# zkReveal v1

zkReveal v1 is a minimal on-chain receipt and settlement layer for digital sellers.

Buyer pays.  
Seller gets paid.  
Your backend receives a verifiable on-chain purchase receipt.

Receipt Mode lets sellers create fixed-price listings or accept seller-authorized dynamic quotes. The contract settles funds immediately, emits `ReceiptPurchased`, and records the seller net payment with `SellerPaid` so seller bots, APIs, dashboards, or indexers can fulfill orders off-chain.

v1 is Receipt Mode only.

- v1 is not Delivery Mode
- v1 is not Escrow Mode
- v1 does not support refunds or reclaim flows
- v1 does not support buyer public keys, encrypted payloads, content CIDs, inventory units, or delivery deadlines
- v1 does not do dynamic on-chain pricing, oracle pricing, or marketplace fee routing
- v1 does not expose cross-chain gateway adapter entrypoints

## Product Model

zkReveal v1 receipt mode has two immutable on-chain components:

- `PurchaseRefRegistry` is the canonical replay-protection primitive. It consumes each
  protocol-scoped `purchaseRef` once and stores which authorized settlement contract or module
  consumed it. Random wallets cannot consume refs directly. The registry owner may authorize or
  deauthorize settlement modules for future use, but cannot delete or unconsume refs that have
  already been consumed.
- `RevealReceiptStore` is the seller-facing receipt settlement contract. It manages listings,
  signatures, payment settlement, and receipt records.

Current and future zkReveal settlement contracts only share replay protection when they point to
the same `PurchaseRefRegistry`. Adding a future settlement module requires authorizing that module
in the shared registry.

### Deployment Note

`RevealReceiptStore` must be authorized as a `PurchaseRefRegistry` consumer before purchases can
settle. The deployment script handles this by deploying the registry with the deployer as temporary
owner, authorizing the receipt store, and then transferring registry ownership to
`PROTOCOL_OWNER`.

## Purchase Modes

For production checkout/payment-link flows, prefer signed quotes.

### `purchaseReceipt(listingId, purchaseRef)`

- Public fixed-price listing purchase.
- Uses the listing's current `unitPrice` at execution time.
- Does not bind the buyer before submission.
- Anyone who submits a valid unconsumed `purchaseRef` and pays first receives the receipt.
- Suitable for simple public listings where any buyer may purchase.
- Not recommended for seller-issued private payment links, Telegram checkout links, order-specific checkout, buyer-specific checkout, dynamic pricing, or integrator-fee flows.

### `purchaseSignedReceipt(quote, sellerSignature)`

- Recommended default for production checkout/payment-link flows.
- Uses a seller-authorized EIP-712 quote.
- Binds buyer, listingId, seller, amount, purchaseRef, metadataHash, settlementToken, purchaseRefRegistry, expiry, chain, and contract.
- Prevents another wallet from using the same seller-issued quote because `quote.buyer` must match `msg.sender`.
- Supports dynamic pricing and optional integrator fees.
- Use this for Telegram bot flows, seller-issued order links, private links, custom pricing, and partner or integrator checkouts.

### Fixed-price receipt flow

Buyer Proof Mode fits inside the fixed-price path.

1. Create a fixed-price listing with `createListing(listingHash, unitPrice)`.
2. Optionally update the fixed listing price with `setListingPrice(listingId, newUnitPrice)`.
3. Optionally pause or resume the listing with `setListingActive(listingId, active)`.
4. Agree on a `rawPurchaseRef` off-chain and derive the canonical protocol-scoped `purchaseRef` with `hashPurchaseRef(seller, listingId, rawPurchaseRef)`, or compute the same hash off-chain.
5. Buyer approves the settlement token and calls `purchaseReceipt(listingId, purchaseRef)`.

`purchaseReceipt` is the direct fixed-price purchase path. It uses the listing's current `unitPrice`, is public, and is not buyer-bound before submission. Anyone who submits a valid unconsumed `purchaseRef` and pays first receives the receipt. It does not support integrator fees. The raw reference stays off-chain; only the derived `bytes32` hash is submitted. For production checkout/payment-link flows, prefer signed quotes.

`listingHash` is an opaque seller-defined metadata commitment. Human-readable product data lives off-chain, for example inside a seller-signed payment link or checkout payload.

### Signed quote receipt flow

Seller Payment Link Mode fits inside the signed quote path and is the recommended default for production checkout flows.

1. Seller backend creates an order, generates a short off-chain `rawPurchaseRef`, and derives the protocol-scoped `purchaseRef` hash.
2. Seller optionally authorizes a backend or service key once with `setQuoteSigner(signer, true)`.
3. The seller wallet or an authorized quote signer signs a `SignedReceiptQuote` over `listingId`, `buyer`, `purchaseRef`, `amount`, `metadataHash`, optional `integratorFeeRecipient`, optional `integratorFeeAmount`, and `expiresAt`; the EIP-712 digest also binds the listing `seller`, the v1 `settlementToken`, and the immutable `purchaseRefRegistry`.
4. Buyer approves the settlement token and calls `purchaseSignedReceipt(quote, sellerSignature)`.
5. The contract verifies the EIP-712 signature and accepts it when the recovered signer is the seller or a seller-authorized quote signer at purchase time.
6. `ReceiptPurchased` confirms payment, and the seller fulfills the order off-chain.

Signed quotes are the v1 mechanism for dynamic pricing. They do not introduce escrow, delayed settlement, or on-chain price discovery.
`metadataHash` must be non-zero and should commit to the readable off-chain payment-link or checkout metadata the seller intends to authorize.

Use `validateSignedReceiptPurchase(quote, sellerSignature, expectedBuyer)` when a frontend, bot, or backend wants the same validation path as `purchaseSignedReceipt` without moving funds or creating a receipt.

Use `previewSignedReceiptPurchase(quote)` only for fee math. It does not verify the seller signature, buyer match, expiry, listing active status, or replay state.

Dynamic signed quotes may be signed either by the seller wallet directly or by an authorized quote signer. This lets a seller keep the settlement wallet separate from a backend hot key. The seller authorizes a signer once with `setQuoteSigner`, and that signer can create dynamic quotes for the seller's listings.

Authorized quote signers can sign dynamic receipt quotes for any listing owned by that seller. Revoke compromised signers immediately with `setQuoteSigner(signer, false)`.

### Integrator fees

Integrator fees are supported only through seller-authorized signed quotes.

This lets marketplaces, bots, checkout frontends, dashboards, and other seller tools monetize without changing seller settlement semantics. The seller or authorized quote signer includes `integratorFeeRecipient` and `integratorFeeAmount` in the signed quote.

On purchase, zkReveal pays:

1. protocol fee
2. integrator fee, if present
3. seller net amount

`receipt.amount` remains the gross amount paid. Fee breakdowns should be indexed from `ProtocolFeePaid` and `IntegratorFeePaid`.

## Signed Quote Typed Data

TypeScript signing shape:

```ts
const domain = {
  name: "RevealReceiptStore",
  version: "1",
  chainId,
  verifyingContract: receiptStoreAddress,
};

const types = {
  SignedReceiptQuote: [
    { name: "listingId", type: "uint256" },
    { name: "seller", type: "address" },
    { name: "buyer", type: "address" },
    { name: "purchaseRef", type: "bytes32" },
    { name: "amount", type: "uint256" },
    { name: "metadataHash", type: "bytes32" },
    { name: "settlementToken", type: "address" },
    { name: "purchaseRefRegistry", type: "address" },
    { name: "integratorFeeRecipient", type: "address" },
    { name: "integratorFeeAmount", type: "uint256" },
    { name: "expiresAt", type: "uint64" },
  ],
};

const message = {
  listingId,
  seller, // always the listing seller address
  buyer,
  purchaseRef,
  amount,
  metadataHash, // hash of seller-defined readable checkout metadata
  settlementToken,
  purchaseRefRegistry,
  integratorFeeRecipient, // zero address when no integrator fee is used
  integratorFeeAmount, // zero when no integrator fee is used
  expiresAt,
};

const signature = await signer.signTypedData(domain, types, message);
```

The `seller` field in typed data is always the listing seller address, even when the signature is produced by an authorized quote signer. `metadataHash` should commit to the readable off-chain payment-link or checkout metadata you want the seller signature to protect. The contract accepts seller-wallet signatures or authorized quote-signer signatures if authorization exists at purchase time.

The signed EIP-712 type is:

```text
SignedReceiptQuote(uint256 listingId,address seller,address buyer,bytes32 purchaseRef,uint256 amount,bytes32 metadataHash,address settlementToken,address purchaseRefRegistry,address integratorFeeRecipient,uint256 integratorFeeAmount,uint64 expiresAt)
```

## Quote Signer Security

`setQuoteSigner(signer, true)` authorizes `signer` at seller scope.

- A seller-authorized quote signer can sign dynamic quotes for any listing owned by that seller.
- Treat quote signers as hot operational keys.
- Use a dedicated backend signer instead of the seller treasury key as a hot service key.
- Rotate or revoke signers when team members, servers, or environments change.
- Monitor signed quote generation in backend logs.
- If a signer is compromised, revoke it immediately with `setQuoteSigner(signer, false)`.
- Future versions may support per-listing signer scope, but v1 signer scope is seller-wide.

## Hashes, Metadata, and Privacy

`listingHash`, `purchaseRef`, and `metadataHash` are opaque commitments and identifiers. They are
not encryption. If the underlying raw value is weak, predictable, or guessable, it may still be
guessed off-chain.

Keep human-readable product, order, and customer data off-chain in the seller backend, bot, or
dashboard.

- `listingHash` commits to seller-defined listing metadata without exposing human-readable product data.
- `metadataHash` binds seller-defined payment-link or checkout metadata without revealing it on-chain.
- `purchaseRef` is the protocol-scoped on-chain hash of an off-chain raw operational order reference.

### Purchase References

In Receipt Mode, zkReveal separates the human-readable off-chain order reference from the
on-chain receipt identifier.

- `rawPurchaseRef` is generated by the seller, bot, frontend, or backend.
- `rawPurchaseRef` stays off-chain.
- `purchaseRef` is the protocol-scoped `bytes32` hash submitted to settlement contracts.
- Canonical replay protection is enforced through `PurchaseRefRegistry.consume(purchaseRef)`, which
  only authorized settlement modules may call.
- `receiptIdBySellerAndPurchaseRef[seller][purchaseRef]` remains in `RevealReceiptStore` only as
  a deterministic reconciliation helper for that store's own receipts.
- The canonical hash is scoped by `zkReveal.purchaseRef.receipt.v1`, `chainId`, settlement token
  address, seller address, and raw purchase reference.

```solidity
purchaseRef = keccak256(abi.encode(
    "zkReveal.purchaseRef.receipt.v1",
    block.chainid,
    address(settlementToken),
    seller,
    rawPurchaseRef
));
```

Because the canonical hash already scopes by chain, settlement token, and seller, the raw
reference should stay short and operational. It should identify the seller-side order in an
external system, not describe the buyer or purchased content.

`listingId` is used only to validate that the listing exists and belongs to the provided seller.
It is not included in the final hash.

Because replay protection is enforced on the final `purchaseRef` hash through a shared
`PurchaseRefRegistry`, the same `purchaseRef` cannot be reused across current or future zkReveal
settlement contracts that share that registry. This also prevents accidental replay across
different listings for the same seller raw order reference. Sellers should still treat each
`rawPurchaseRef` as a unique operational order ID and avoid reusing it across orders.

Restricting `consume` to authorized settlement modules prevents griefing by random wallets that
learn a `purchaseRef` and attempt to consume it directly without paying.

Revoking a consumer only blocks future consumes from that module. It does not unconsume or delete
historical purchase refs that were already recorded in the registry.

Frontend and backend integrations should usually let the contract helper derive the canonical
hash:

```ts
const rawPurchaseRef = `ord_tg_${yyyymmdd}_${uniqueId}`;
const purchaseRef = await receiptStore.hashPurchaseRef(seller, listingId, rawPurchaseRef);
```

`rawPurchaseRef` must be non-empty, must stay off-chain, and must be at most 128 bytes.
`purchaseRef` must remain unique across any checkout flow that shares a `PurchaseRefRegistry`.

Do not use emails, phone numbers, Telegram IDs, usernames, wallet labels, or predictable order
numbers directly as `rawPurchaseRef`.

Prefer random or opaque references such as:

- `ord_tg_20260502_f8K2pQ9z`
- `550e8400-e29b-41d4-a716-446655440000`

Do not put sensitive buyer data, emails, Telegram usernames, private channel names, or plaintext
secrets inside `rawPurchaseRef`.

Hashes are commitments and identifiers, not encryption. Weak or guessable raw references may still
be vulnerable to guessing.

## Fulfillment Responsibility

Receipt Mode is a proof-of-payment and settlement primitive. It is not an escrow or
delivery-verification system.

- Settlement is immediate.
- The contract does not verify delivery, content correctness, access provisioning, product
  quality, refunds, disputes, or whether the seller actually fulfilled the order.
- Seller systems, bots, dashboards, or other off-chain workflows are responsible for fulfillment
  after they detect a valid receipt.
- Buyers and integrators should use trusted sellers or add their own refund or dispute layer
  off-chain.
- This is intentionally different from the older escrow or delivery mode designs.

## Source of Truth

`ListingCreated` and `ReceiptPurchased` are the source-of-truth events for listing and receipt
discovery by seller bots, backends, dashboards, and indexers.
Signed quote purchases emit the signed `metadataHash`; direct fixed-price purchases emit `bytes32(0)`.
`SellerPaid` records the seller net amount after protocol and integrator fees. `ProtocolFeePaid`
and `IntegratorFeePaid` expose the rest of the payout breakdown.

Backends can reconcile purchases by:

- `seller`
- `purchaseRef`

If seller systems also need product context, they should resolve it off-chain from
`rawPurchaseRef`, `purchaseRef`, `listingId`, or `listingHash`.

The contract also stores:

- `PurchaseRefRegistry.consumptions[purchaseRef]` as the canonical replay-protection record
- `receiptIdBySellerAndPurchaseRef[seller][purchaseRef]`
- `receipts[receiptId]`
- `listingCountBySeller[seller]` only to enforce `MAX_LISTINGS_PER_SELLER`

`receiptIdBySellerAndPurchaseRef` is not the replay-protection source of truth. It is a local
lookup helper for seller and indexer reconciliation after settlement.

## Fee Model

The v1 fee model is immutable at deployment:

- `settlementToken`
- `feeRecipient`
- `protocolFeeBps`

Constraints:

- `protocolFeeBps` is capped at `MAX_PROTOCOL_FEE_BPS = 1_000` basis points
- `integratorFeeAmount` in signed quotes is capped at `MAX_INTEGRATOR_FEE_BPS = 1_000` basis points of the quoted `amount`
- `feeRecipient` must be non-zero when `protocolFeeBps > 0`
- `integratorFeeRecipient` must be the zero address when `integratorFeeAmount = 0`
- `integratorFeeRecipient` must be non-zero when `integratorFeeAmount > 0`
- official v1 deployments are intended for a 6-decimal settlement token such as USDC
- `MIN_PURCHASE_AMOUNT = 1e6` and `MAX_PURCHASE_AMOUNT = 5_000e6` assume 6 decimals
- deploying with an 18-decimal token changes the practical meaning of those caps and is not recommended unless constants are adjusted in a future version
- for Arbitrum mainnet, use the canonical or native USDC deployment intended by the project
- `settlementToken` should be a standard ERC-20 such as USDC
- fee-on-transfer and rebasing tokens are not supported

There is no dynamic fee mutation in v1.

## Safety Controls

`RevealReceiptStore` is owned and uses `Ownable2Step` for admin transfers.

The owner can independently pause:

- listing creation
- purchases
- quote signer updates

v1 also enforces conservative hard caps:

- min purchase: 1 USDC (`1e6`) assuming a 6-decimal settlement token
- max purchase: 5,000 USDC (`5_000e6`) assuming a 6-decimal settlement token
- max quote TTL: 24 hours
- max listings per seller: 50
- max quote signers per seller: 3

Integration guide:

- [`docs/receipt-mode-integration.md`](docs/receipt-mode-integration.md)

## Contract Surface

Core contract:

- `src/PurchaseRefRegistry.sol`
- `src/RevealReceiptStore.sol`

Key functions:

- `consume`
- `isConsumed`
- `consumedBy`
- `createListing`
- `setQuoteSigner`
- `setListingActive`
- `setListingPrice`
- `hashPurchaseRef`
- `purchaseReceipt`
- `purchaseSignedReceipt`
- `quotePurchaseReceipt`
- `previewSignedReceiptPurchase`
- `validateSignedReceiptPurchase`
- `hashSignedReceiptQuote`
- `getReceiptIdBySellerAndPurchaseRef`

Key events:

- `ListingCreated`
- `ListingStatusChanged`
- `ListingPriceChanged`
- `QuoteSignerAuthorizationChanged`
- `ReceiptPurchased`
- `SellerPaid`
- `ProtocolFeePaid`
- `IntegratorFeePaid`

## Development

```bash
forge fmt
forge test
```

If Foundry crashes during trace signature lookup in your local environment, retry with:

```bash
forge test --offline --suppress-successful-traces
```

## Deployment

The v1 deploy script deploys `PurchaseRefRegistry` first and then deploys `RevealReceiptStore`
with that registry address wired into the constructor.

Official v1 deployments are intended for a 6-decimal settlement token such as USDC.
`MIN_PURCHASE_AMOUNT = 1e6` and `MAX_PURCHASE_AMOUNT = 5_000e6` assume 6 decimals.
Deploying with an 18-decimal token changes the practical meaning of those caps and is not
recommended unless a future version adjusts the constants.

For Arbitrum mainnet, use the canonical/native USDC deployment intended by the project.

Required envs:

- `RPC_URL`
- `PRIVATE_KEY`
- `SETTLEMENT_TOKEN`
- `FEE_RECIPIENT`
- `PROTOCOL_FEE_BPS`

Optional envs:

- `PROTOCOL_OWNER` to override the default owner; otherwise the deployer is used

`FEE_RECIPIENT` may be the zero address only when `PROTOCOL_FEE_BPS=0`.
If `PROTOCOL_FEE_BPS=0`, `FEE_RECIPIENT` may also be omitted and the deploy script will default it to the zero address.

The deploy output logs both:

- `PurchaseRefRegistry`
- `ReceiptStore`

If a future zkReveal settlement contract must share replay protection with an existing deployment,
it should be deployed against the same `PurchaseRefRegistry` address.

Typical flow:

```bash
export RPC_URL="https://your-arbitrum-sepolia-rpc"
export PRIVATE_KEY="0xYOUR_PRIVATE_KEY"
export SETTLEMENT_TOKEN="0xYOUR_ERC20_ON_ARBITRUM_SEPOLIA"
export FEE_RECIPIENT="0xYOUR_FEE_RECIPIENT"
export PROTOCOL_FEE_BPS="0"
# optional:
export PROTOCOL_OWNER="0xYOUR_OWNER"

forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC_URL" --broadcast
```

After deployment, record:

- chain ID
- `PurchaseRefRegistry` address
- `ReceiptStore` address
- registry deploy transaction hash
- receipt store deploy transaction hash
- registry authorization transaction hash
- settlement token
- fee recipient
- protocol owner
- registry owner
- protocol fee bps

Current Arbitrum Sepolia deployment as of 2026-05-05:

- chain ID: `421614`
- `PurchaseRefRegistry`: `0x18E806446a46be35B5AF7488489c721b419e3Ae8`
- registry deploy tx: `0x0792017e12748256d7b63ae6a6395d09d90bb6f267731dd23e80a1604bc7cd24`
- registry deploy block: `265681261`
- `ReceiptStore`: `0x106Cfb8CC6E0ce19F62B64aB848314B2b2288Fb1`
- receipt store deploy tx: `0xc754da5a55b0f9ef8eccc4032455db2bb0fc52a0d6e2ddefe4ed191266d4b10c`
- receipt store deploy block: `265681302`
- registry authorization tx: `0x06188cd7f6060975a12e0b8ddbaded504e88e76f46a2e8539994130ba3a67a7c`
- registry authorization block: `265681324`
- settlement token: `0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d`
- fee recipient: `0xdEf8E3337A9E914aBc7bC93230a3AA795De6FB36`
- protocol owner: `0xc3549AAc0EB0F3310e116BC72B03B20ae8a1e03e`
- registry owner: `0xc3549AAc0EB0F3310e116BC72B03B20ae8a1e03e`
- receipt store authorized in registry: `true`
- protocol fee bps: `500`

## Roadmap

Future roadmap may include Protected Delivery, Escrow Mode, or gateway adapters for pay-from-other-chain UX, but those are not part of zkReveal v1.

The v1 core is intentionally focused on receipt-mode settlement and off-chain fulfillment.
