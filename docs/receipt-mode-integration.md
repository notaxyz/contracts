# Receipt Mode Integration Guide

For production checkout and payment-link flows, prefer signed quotes.

## Architecture

Nota receipt mode has two immutable contracts:

- `PurchaseRefRegistry` is the canonical replay-protection layer. It consumes a `purchaseRef`
  once globally for every settlement contract that shares the registry.
- `NotaReceiptStore` handles listings, signatures, and settlement.

`NotaReceiptStore` stores no receipt records. Settlement emits `ReceiptPurchasedV2`, which is the
receipt. `seller`, `buyer`, and `purchaseRef` are indexed, so reconciling a purchase reference to
its settlement is a direct `eth_getLogs` filter on the `purchaseRef` topic.

## Purchase Modes

### Use `purchaseReceipt(listingId, purchaseRef, amount)` only when:

- the listing is public and fixed-price
- any buyer may purchase
- you do not need buyer pre-binding
- you do not need dynamic pricing
- you do not need integrator fees

This path is simple and public. It is not buyer-bound before submission. Anyone who submits a
valid unconsumed `purchaseRef` first and pays first receives the receipt.

`amount` is the buyer's exact-price assertion. The contract reverts with `PriceMismatch` if
`listing.unitPrice != amount`. Listing prices are immutable in v1 (there is no `setListingPrice`)
— to change a product's price, the seller creates a new listing. Frontends should set the ERC-20
allowance to exactly `amount`, not `type(uint256).max`, both as defense-in-depth and so any
client-side cache vs. chain mismatch fails fast at the allowance check.

Do not use this path for seller-issued private links, Telegram checkout links, order-specific
checkout, buyer-specific checkout, dynamic pricing, or integrator-fee flows.

### Use `purchaseSignedReceipt(quote, sellerSignature)` when:

- the flow is a real checkout or payment link
- the buyer may optionally be pre-bound (set `buyer` to bind, or to the zero address to leave unbound)
- pricing may vary per order
- seller metadata should be committed in the signature
- integrator fees may apply

This is the recommended default for frontend and backend integrators.

The EIP-712 quote binds:

- buyer
- listing ID
- seller
- amount
- purchase reference
- metadata hash
- settlement token
- purchaseRefRegistry
- issuedAt
- expiry
- chain
- contract

`buyer` binding is optional. When `quote.buyer` is a non-zero address it must match `msg.sender`,
so another wallet cannot redeem the same seller-issued quote. When `quote.buyer` is the zero
address the quote is unbound and any wallet may submit and pay; the single-use `purchaseRef` still
prevents the quote from being redeemed more than once.

`issuedAt` is the seller-declared quote issuance timestamp and part of the signed EIP-712
payload. A signed quote is valid only between `issuedAt` and `expiresAt`, and
`expiresAt - issuedAt` must not exceed `MAX_QUOTE_TTL`.

Use `validateSignedReceiptPurchase(quote, sellerSignature, expectedBuyer)` when you want the same
validation path as `purchaseSignedReceipt` without moving funds or creating a receipt.

Use `previewSignedReceiptPurchase(quote)` only for fee math. It does not verify signature, buyer
match, quote expiry, listing status, or replay status.

Listing and receipt discovery should be handled from `ListingCreated` and `ReceiptPurchasedV2`
events or by an indexer, not by on-chain enumeration.

## Hashes, Metadata, and Privacy

`listingHash`, `purchaseRef`, and `metadataHash` are opaque commitments and identifiers. They are
not encryption. If the raw underlying value is weak, predictable, or guessable, it may still be
guessed off-chain.

Keep human-readable product, order, and customer data off-chain in seller backends, bots, or
dashboards.

- `listingHash` commits to seller-defined listing metadata without exposing human-readable product data
- `metadataHash` binds seller-defined payment-link or checkout metadata without revealing it on-chain
- `purchaseRef` is the protocol-scoped on-chain hash of an off-chain
  `(rawPurchaseRef, purchaseRefNonce)` bundle

### Canonical Checkout Metadata

For signed-quote purchases, `metadataHash` commits to seller-defined off-chain **checkout / payment-intent**
metadata — the exact intent the seller is authorizing. It is not product blobs, not secrets, and not buyer PII.

```
metadataHash = keccak256(utf8Bytes(canonicalize(checkoutMetadata)))
```

Use JSON Canonicalization Scheme (JCS)-style serialization (stable key order, normalized values) before
hashing. **Never** hash raw `JSON.stringify()` output unless the runtime guarantees deterministic key
ordering and value normalization.

Recommended v1 shape (`schema: "nota.checkout.metadata.v1"`):

```json
{
  "schema": "nota.checkout.metadata.v1",
  "protocol": {
    "name": "Nota",
    "version": "1",
    "chainId": 421614,
    "receiptStore": "0x...",
    "settlementToken": "0x..."
  },
  "seller": "0x...",
  "listing": {
    "listingId": "1",
    "listingHash": "0x..."
  },
  "quote": {
    "buyer": "0x0000000000000000000000000000000000000000",
    "purchaseRef": "0x...",
    "amount": "1000000",
    "currency": "USDC",
    "decimals": 6,
    "issuedAt": 1760000000,
    "expiresAt": 1760003600
  },
  "checkout": {
    "kind": "agent_topup",
    "title": "Top up 10 AI credits",
    "description": "Credit top-up for demo agent",
    "externalOrderId": "topup_7f3a9c"
  },
  "integrator": {
    "name": "Acme",
    "recipient": "0x...",
    "feeAmount": "0"
  }
}
```

**Include in the hash:** `schema`; `protocol` (`chainId`, `receiptStore`, `settlementToken`); `seller`;
`listing.listingId`; `listing.listingHash`; `quote.buyer` (even if the zero address); `quote.purchaseRef`;
`quote.amount`; `quote.issuedAt` / `quote.expiresAt`; `checkout.kind`; `checkout.title`; and optionally
`checkout.externalOrderId` and the success / cancel URLs.

**Never in the hash:** `purchaseRefNonce`, unlock / delivery secrets, private invite links, emails, phone
numbers, Telegram IDs / usernames, or any other buyer PII. `metadataHash` is a public commitment that is
verifiable against chain data — it is **not** encryption.

`checkout.kind` is an **application-defined string** (lowercase snake_case, 1–64 chars, matching
`^[a-z0-9][a-z0-9_:-]*$`, with `:` allowed for namespacing) such as `payment_link`, `telegram_bot`,
`agent_topup`, `merchant_api`, or a namespaced value like `x402:agent_request`. It is intentionally not a
fixed enum, so new checkout flows do not require a schema bump.

Direct `purchaseReceipt` purchases emit `metadataHash = bytes32(0)`; `purchaseSignedReceipt` requires a
non-zero `metadataHash`. The contract only ever sees and emits the resulting `bytes32`; the readable
metadata lives in the seller backend, merchant API, bot session, or dashboard.

### Purchase Reference Scoping

- canonical replay protection is enforced through `PurchaseRefRegistry.consume(purchaseRef)`
- receipts are not stored on-chain; `ReceiptPurchasedV2` is the record
- the canonical helper is `hashPurchaseRef(seller, listingId, rawPurchaseRef, purchaseRefNonce)`
- the canonical hash includes the domain string, `block.chainid`, settlement token address,
  seller, the raw purchase reference, and the secret `purchaseRefNonce`

`rawPurchaseRef` is the human/business identifier; `purchaseRefNonce` is a secret high-entropy
32-byte salt generated with a CSPRNG. The two together form the off-chain entitlement bundle shared
seller→buyer — only the resulting `bytes32` hash is submitted on-chain. The cryptographic strength of
the commitment comes from `purchaseRefNonce`: even a guessable `rawPurchaseRef` (e.g. `invoice-123`)
cannot be brute-forced into the on-chain `purchaseRef` without the nonce.

`listingId` is used only to validate that the listing exists and belongs to the provided seller.
It is not part of the final hash.

Because replay protection is enforced on the final hash through a shared `PurchaseRefRegistry`,
the same `purchaseRef` cannot be reused across current or future Nota settlement contracts
that share that registry. This also prevents accidental replay across different listings for the
same seller raw order reference. Sellers should still treat every raw reference as a unique
operational order ID and avoid reusing it across orders.

Keep raw purchase references off-chain.

Do not use:

- emails
- phone numbers
- Telegram IDs
- usernames
- wallet labels
- predictable order numbers

Prefer the canonical `<namespace>_<context>_<random>` format — an issuing brand/merchant slug, a
lowercased flow or service id, and an opaque high-entropy (>=128-bit) random suffix:

- `rev_topup_4f8c1d9a2b7e6035a1c4d8e9f0b2a6c3`
- `GG_credit_topup_9b1c0a7f5e2d43687a0f2c9b1e6d4a08`

The `namespace` and `context` are operational labels only; the high-entropy `random` suffix is what
keeps the reference unguessable. This is a convention enforced off-chain by the issuer — the
contract only checks that `rawPurchaseRef` is 1..128 bytes, since at settlement it sees just the
`bytes32` hash.

## Deployment Integration

Deploy `PurchaseRefRegistry` before `NotaReceiptStore`.

`NotaReceiptStore` constructor arguments now include the registry address. To preserve
protocol-level replay protection across future settlement contracts, deploy those contracts
against the same `PurchaseRefRegistry` address.

## Fulfillment Responsibility

Receipt Mode is a proof-of-payment and settlement primitive. It is not an escrow or
delivery-verification system.

- settlement is immediate
- the contract does not verify delivery, content correctness, access provisioning, product
  quality, refunds, disputes, or whether the seller actually fulfilled the order
- seller systems, bots, dashboards, and off-chain workflows are responsible for fulfillment after
  observing a valid receipt
- buyers and integrators should use trusted sellers or add their own off-chain refund or dispute layer

## Quote Signer Security

`setListingQuoteSigner(listingId, signer, true)` authorizes a signer for one seller-owned listing.

- that signer can sign quotes only for that listing
- a signer authorized for one listing cannot sign valid quotes for another listing unless separately authorized there
- a listing-authorized quote signer can set the full signed quote intent for that listing, including amount, metadataHash, buyer binding, purchaseRef, and optional integrator fee fields
- use `isQuoteSignerAuthorized(listingId, signer)` when frontend or backend code needs one check for seller-direct and delegated signer authority
- deactivating a listing blocks purchases but does not revoke quote signers; revoke compromised signers explicitly
- treat quote signers as hot operational keys
- use a dedicated backend signer instead of a treasury key as a hot service key
- rotate or revoke signers when team members or servers change
- monitor signed quote generation in backend logs
- revoke compromised signers immediately with `setListingQuoteSigner(listingId, signer, false)`

The seller wallet itself remains a valid direct signer without being registered as a delegated quote signer.

## Settlement Token Assumption

Official v1 deployments are intended for 6-decimal settlement tokens such as USDC.

- `MIN_PURCHASE_AMOUNT = 1e6` assumes 1 USDC
- there is no protocol-level maximum purchase amount in this contract
- large purchases are controlled by seller quote policy, frontend/backend limits, token allowance and balance, and operational risk controls
- deploying with an 18-decimal token changes the practical meaning of the minimum purchase amount and is not recommended unless a future version adjusts the constants

For Arbitrum mainnet, use the canonical or native USDC deployment intended by the project.
