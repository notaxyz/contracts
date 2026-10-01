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

Sellers can additionally record sales that were paid outside the contract with `attestReceipt`,
which emits `ReceiptAttested`. See [Attested Receipts](#attested-receipts) below before indexing
it; it is not a purchase and must not be reconciled as one.

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
`listing.unitPrice != amount`. Listing prices are immutable in the contract (there is no `setListingPrice`)
— to change a product's price, the seller creates a new listing. Frontends should set the ERC-20
allowance to exactly `amount`, not `type(uint256).max`, both as defense-in-depth and so any
client-side cache vs. chain mismatch fails fast at the allowance check.

Do not use this path for seller-issued private links, Telegram checkout links, order-specific
checkout, buyer-specific checkout, dynamic pricing, or integrator-fee flows.

### Use `purchaseSignedReceipt(quote, sellerSignature, claimedSigner)` when:

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
- agent ID
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

Use `validateSignedReceiptPurchase(quote, sellerSignature, expectedBuyer, claimedSigner)` when you want the same
validation path as `purchaseSignedReceipt` without moving funds or creating a receipt.

Use `previewSignedReceiptPurchase(quote)` only for fee math. It does not verify signature, buyer
match, quote expiry, listing status, or replay status.

Listing and receipt discovery should be handled from `ListingCreated` and `ReceiptPurchasedV2`
events or by an indexer, not by on-chain enumeration.

## Attested Receipts

`attestReceipt(listingId, buyer, purchaseRef, metadataHash, agentId, paymentRef)` lets the
listing's seller record a sale that was paid somewhere other than this contract: a card rail, a
different chain, an off-chain invoice.

What it does:

- consumes `purchaseRef` in the shared `PurchaseRefRegistry`, so the reference can never later be
  purchased on this store or on any other store sharing the registry, and a reference that has
  already been purchased cannot be attested
- emits `ReceiptAttested(receiptId, seller, buyer, listingId, purchaseRef, metadataHash, agentId, paymentRef)`
  with `seller`, `buyer`, and `purchaseRef` indexed, the same topic layout as `ReceiptPurchasedV2`
- draws `receiptId` from the same counter as purchases

What it does not do:

- move any funds. The caller's, the seller's, and the contract's settlement-token balances are
  untouched, no fee is charged, and no `SellerPaid`, `ProtocolFeePaid`, or `IntegratorFeePaid` is
  emitted
- verify that a payment happened. `ReceiptAttested` is a seller claim. Nothing on-chain backs it
  the way a `ReceiptPurchasedV2` is backed by an actual USDC transfer

Rules enforced by the contract:

- only the listing's seller may call it; authorized quote signers cannot
- the listing must exist and be active
- `purchasesPaused` blocks it, together with the purchase paths
- `purchaseRef` must be non-zero and not yet consumed
- `metadataHash` must be non-zero, as on `purchaseSignedReceipt`. With no payment for the contract to
  observe, the commitment is the only substance the attestation has
- `buyer` may be the zero address
- `agentId` and `paymentRef` are opaque `bytes32` values, emitted verbatim, with zero meaning
  unspecified. The contract validates neither

Known limitation: consuming the ref is replay protection, not proof of ownership. The contract checks
that the caller owns the listing, not that the `purchaseRef` was issued by them, so a seller who learns
another seller's unredeemed ref can consume it against their own listing for the cost of gas, after
which the victim's quote can never be redeemed on any store sharing the registry. `purchaseReceipt` has
always allowed the same at the cost of a purchase. Refs are high-entropy and reach only whoever holds
the payment link, so the exposure is unredeemed quotes and the attacker is someone the link reached.
The burned ref also reads as consumed in the registry, which is why a verifier must never treat
consumption as a sale; see [Verifying a Receipt](#verifying-a-receipt). Tracked as
[notaxyz/contracts#8](https://github.com/notaxyz/contracts/issues/8).

Indexing guidance:

- filter `ReceiptAttested` by the same `seller`, `buyer`, or `purchaseRef` topics you use for
  `ReceiptPurchasedV2`
- do not decode one event as the other. They have different `topic0` values, and `ReceiptAttested`
  has no `amount` field
- surface attestations to buyers and downstream systems as *seller-attested*, distinct from
  on-chain-settled purchases

Privacy rules are the same as on the purchase paths. `purchaseRef` is the hash; `rawPurchaseRef`
and `purchaseRefNonce` stay off-chain. `metadataHash` must be the JCS-canonicalized commitment
described under [Canonical Checkout Metadata](#canonical-checkout-metadata) and must never commit to
`purchaseRefNonce`, unlock / delivery secrets, private invite links, emails, phone numbers, Telegram
IDs / usernames, or any other buyer PII.

`paymentRef` is the pointer a verifier follows to confirm the payment happened. For x402 it is the
settlement transaction hash itself: it is already public and already a hash, and hashing it again
would make the binding unverifiable without a side channel. Never put a raw off-chain rail identifier
or anything that identifies the buyer in it. `paymentRef` is not unique and must never be used as a
key; see [Verifying a Receipt](#verifying-a-receipt).

`attestReceipt` is not present on the Base v2 deployment; check the `deployments/` manifest for the
address you integrate against before relying on it.

## Verifying a Receipt

### The registry is replay protection, not evidence

`PurchaseRefRegistry` answers two questions, and neither of them is "did this sale happen":

- `isConsumed(purchaseRef)` answers whether *some* authorized store has consumed the ref. It says
  nothing about which seller, which listing, or what was sold.
- `consumedBy(purchaseRef)` answers *which store* consumed it. That is a settlement contract
  address, not a seller and not a listing.

Any seller can consume any ref they learn against their own listing (see the known limitation under
[Attested Receipts](#attested-receipts)), so consumption carries no information about who owned the
ref. If seller B burns seller A's unredeemed ref, `isConsumed` returns `true` and no `ReceiptAttested`
or `ReceiptPurchasedV2` from A exists anywhere. The registry is answering truthfully about the wrong
question.

### The event is the record

To verify a claimed sale, resolve the `purchaseRef` to its `ReceiptAttested` or `ReceiptPurchasedV2`
log and check all of the following, in order:

0. **The log came from the store you integrate against.** Filter `eth_getLogs` by that store's
   address from the `deployments/` manifest. Any contract can emit a log with the same signature and
   topics; a log from any other address is not a receipt, and every check below is meaningless on it.
1. **A log exists for that `purchaseRef`.** It is an indexed topic, so plain `eth_getLogs` resolves it
   without an indexer. At most one exists across every store sharing the registry, because the ref
   is single-use.
2. **`seller` is the party you expected to sell to you.**
3. **`listingId` belongs to that seller.** Read it back with `getListing(listingId)` and compare
   `seller` (and `listingHash`, if you expected a specific listing). A listing's seller never
   changes, so on the right store this always matches; a mismatch means you are reading the wrong
   contract.
4. **`metadataHash` equals keccak256 over the JCS-canonicalized bytes you actually received.** Hash
   them as received. Never parse and re-serialize first: that verifies your serializer, not the
   seller's commitment.
5. **Only then follow `paymentRef`** (`ReceiptAttested` only). `ReceiptPurchasedV2` carries no
   `paymentRef` because the payment is the settlement itself.

`paymentRef` is unvalidated and not unique: a seller may emit any number of attestations carrying
the same one. Never key an attestation on it. `purchaseRef` is the key: single-use, and enforced
globally by the shared registry.

Two shortcuts each fail in a specific way:

- **Stopping at step 1** can be fooled by any seller who learned the ref. A log exists, but it may
  name a seller and listing that are not the ones you dealt with.
- **Stopping at `isConsumed`** can read a burned ref as a completed sale when no receipt from the
  expected seller exists at all.

### What a passing check establishes

A receipt that passes every step establishes that the named seller published, at that block, a
commitment to exactly those bytes and, for an attestation, against a payment reference it chose. For `ReceiptAttested` it
does not establish that the payment happened. For either event it does not establish that delivery
happened or that the content is correct; see [Fulfillment Responsibility](#fulfillment-responsibility).
On `ReceiptAttested`, `buyer` is whatever address the seller passed: it may be zero, and it may name a
third party who never took part. It is part of the seller's claim, not evidence about the buyer.

What it does establish is that the seller cannot now claim it sold something else.

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

Recommended metadata schema (`schema: "nota.checkout.metadata.v1"`):

```json
{
  "schema": "nota.checkout.metadata.v1",
  "protocol": {
    "name": "Nota",
    "version": "1",
    "chainId": 8453,
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

`attestReceipt` requires a non-zero `metadataHash` and holds it to the same rules: it should be the same
canonical commitment, and it must never commit to secrets or buyer PII.

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

- `nota_topup_4f8c1d9a2b7e6035a1c4d8e9f0b2a6c3`
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

Official deployments are intended for 6-decimal settlement tokens such as USDC.

- `MIN_PURCHASE_AMOUNT = 1e2` assumes 6 decimals and means 0.0001 USDC
- there is no protocol-level maximum purchase amount in this contract
- large purchases are controlled by seller quote policy, frontend/backend limits, token allowance and balance, and operational risk controls
- deploying with an 18-decimal token changes the practical meaning of the minimum purchase amount and is not recommended unless a future version adjusts the constants

For Base mainnet, use Circle's native USDC. The historical Arbitrum One v1 deployment also used
Circle's native USDC, but Base is the canonical v2 network.

## Signing a Quote

`claimedSigner` names who produced the signature: `address(0)` for the listing seller, or the
delegate's address when a listing-authorized quote signer signed. The contract requires both that
the named address is authorized and that the signature verifies against it, so naming an address
grants nothing on its own.

Quote verification uses `SignatureChecker`, so a seller on a smart wallet (Coinbase Smart Wallet,
Safe) can sign quotes. Pass `address(0)` exactly as an EOA seller would — the wallet address is the
listing seller either way.

### Smart-wallet quotes expire on key rotation

An ERC-1271 signature is valid only while the wallet still vouches for it. **If a seller rotates
the owners of their smart wallet, every quote that wallet previously signed becomes invalid
immediately, including unexpired ones.** No event marks this; the next purchase attempt simply
reverts with `InvalidQuoteSigner`.

If you generate payment links:

- treat `expiresAt` as an upper bound on validity, not a guarantee of it
- re-run `validateSignedReceiptPurchase` right before prompting the buyer to pay, not once at link
  creation time
- re-issue outstanding links after a seller rotates wallet keys

EOA sellers are unaffected — ECDSA signatures do not expire this way.

## Agent Attribution (`agentId`)

`agentId` is an opaque `bytes32` in the signed quote, emitted in `ReceiptPurchasedV2`. Use it to
carry an ERC-8004-style agent identifier — a registry-scoped ID or a hash of one. Zero means
unspecified; the direct `purchaseReceipt` path always emits zero.

The seller sets it, inside the signed payload. That is deliberate: the buyer is the agent, and a
self-declared identity proves nothing. The seller attests to it the same way they attest to
`metadataHash`.

**It is seller-attested, not chain-verified.** The contract does not validate `agentId` or resolve
it against any registry — hard-coding a registry address would couple the protocol to one ID
scheme. A receipt carrying an `agentId` means *the seller claims* this sale was to that agent, and
is worth exactly as much as that seller's own verification of the claim. Resolve and judge it
off-chain accordingly.

It is not an indexed event topic. Filter on `seller`, `buyer`, or `purchaseRef` and read `agentId`
from the log data, or index it in a subgraph for agent-level rollups.
