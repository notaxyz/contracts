# Receipt Mode Integration Guide

For production checkout and payment-link flows, prefer signed quotes.

## Purchase Modes

### Use `purchaseReceipt(listingId, purchaseRef)` only when:

- the listing is public and fixed-price
- any buyer may purchase
- the current on-chain `unitPrice` is acceptable at execution time
- you do not need buyer pre-binding
- you do not need dynamic pricing
- you do not need integrator fees

This path is simple and public. It is not buyer-bound before submission. Anyone who submits a
valid unused `purchaseRef` first and pays first receives the receipt.

Do not use this path for seller-issued private links, Telegram checkout links, order-specific
checkout, buyer-specific checkout, dynamic pricing, or integrator-fee flows.

### Use `purchaseSignedReceipt(quote, sellerSignature)` when:

- the flow is a real checkout or payment link
- the buyer should be pre-bound
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
- expiry
- chain
- contract

Another wallet cannot consume the same seller-issued quote because `quote.buyer` must match
`msg.sender`.

Use `validateSignedReceiptPurchase(quote, sellerSignature, expectedBuyer)` when you want the same
validation path as `purchaseSignedReceipt` without moving funds or creating a receipt.

Use `previewSignedReceiptPurchase(quote)` only for fee math. It does not verify signature, buyer
match, quote expiry, listing status, or replay status.

Listing and receipt discovery should be handled from `ListingCreated` and `ReceiptPurchased`
events or by an indexer, not by on-chain enumeration.

## Hashes, Metadata, and Privacy

`listingHash`, `purchaseRef`, and `metadataHash` are opaque commitments and identifiers. They are
not encryption. If the raw underlying value is weak, predictable, or guessable, it may still be
guessed off-chain.

Keep human-readable product, order, and customer data off-chain in seller backends, bots, or
dashboards.

- `listingHash` commits to seller-defined listing metadata without exposing human-readable product data
- `metadataHash` binds seller-defined payment-link or checkout metadata without revealing it on-chain
- `purchaseRef` is the seller-scoped on-chain hash of an off-chain raw order reference

### Purchase Reference Scoping

- on-chain uniqueness and deterministic reconciliation are enforced through
  `receiptIdBySellerAndPurchaseRef[seller][purchaseRef]`, where `0` means unused
- the canonical helper is `hashPurchaseRef(seller, listingId, rawPurchaseRef)`
- the canonical hash includes the domain string, `block.chainid`, contract address, seller,
  listing ID, and raw purchase reference

Because `listingId` is included, reusing the same raw reference on two different listings
produces two different `purchaseRef` hashes.

Because uniqueness is enforced per seller on the final hash, sellers should still treat every raw
reference as a unique operational order ID and avoid reusing it across orders.

Keep raw purchase references off-chain.

Do not use:

- emails
- phone numbers
- Telegram IDs
- usernames
- wallet labels
- predictable order numbers

Prefer opaque references such as:

- `ord_tg_20260502_f8K2pQ9z`
- `550e8400-e29b-41d4-a716-446655440000`

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

`setQuoteSigner(signer, true)` authorizes a signer at seller scope.

- that signer can sign quotes for any listing owned by the seller
- v1 does not provide per-listing signer scopes
- treat quote signers as hot operational keys
- use a dedicated backend signer instead of a treasury key as a hot service key
- rotate or revoke signers when team members or servers change
- monitor signed quote generation in backend logs
- revoke compromised signers immediately with `setQuoteSigner(signer, false)`

Future versions may support narrower signer scopes, but v1 is seller-wide.

## Settlement Token Assumption

Official v1 deployments are intended for 6-decimal settlement tokens such as USDC.

- `MIN_PURCHASE_AMOUNT = 1e6` assumes 1 USDC
- `MAX_PURCHASE_AMOUNT = 5_000e6` assumes 5,000 USDC
- deploying with an 18-decimal token changes the practical meaning of those caps and is not recommended unless a future version adjusts the constants

For Arbitrum mainnet, use the canonical or native USDC deployment intended by the project.
