# Nota v1

Nota v1 is a minimal on-chain receipt and settlement layer for digital sellers.

Buyer pays.  
Seller gets paid.  
Your backend receives a verifiable on-chain purchase receipt.

Receipt Mode lets sellers create fixed-price listings or accept seller-authorized dynamic quotes. The contract settles funds immediately, emits `ReceiptPurchasedV2`, and records the seller net payment with `SellerPaid` so seller bots, APIs, dashboards, or indexers can fulfill orders off-chain.

v1 is intentionally limited to Receipt Mode.

- v1 records payment, settlement, and receipt creation on-chain

- v1 settles funds immediately

- v1 supports fixed-price listings and seller-authorized signed quotes

- v1 supports protocol fees and optional signed integrator fees

- v1 leaves fulfillment, delivery, refunds, disputes, and customer support to off-chain seller systems

- v1 does not act as a marketplace, escrow system, refund system, or delivery-verification protocol

## What Goes On-Chain

The contracts implement one primitive:

```text
payment → settlement → on-chain receipt
```

Everything else is deliberately kept off-chain, which is also what bounds how much a public receipt
discloses:

- listing metadata is committed as a hash, never stored in full
- purchase references are opaque `bytes32` hashes; the raw reference and its secret nonce stay
  off-chain
- fulfillment, delivery, refunds, disputes, and support live in seller systems
- receipts are events rather than storage, and carry commitments rather than contents

## Product Model

Nota v1 receipt mode has two immutable on-chain components:

- `PurchaseRefRegistry` is the canonical replay-protection primitive. It consumes each
  protocol-scoped `purchaseRef` once and stores which authorized settlement contract or module
  consumed it. Random wallets cannot consume refs directly. The registry owner may authorize or
  deauthorize settlement modules for future use, but cannot delete or unconsume refs that have
  already been consumed.
- `NotaReceiptStore` is the seller-facing receipt settlement contract. It manages listings,
  signatures, payment settlement, and receipt records.

Current and future Nota settlement contracts only share replay protection when they point to
the same `PurchaseRefRegistry`. Adding a future settlement module requires authorizing that module
in the shared registry.

### Deployment Note

`NotaReceiptStore` must be authorized as a `PurchaseRefRegistry` consumer before purchases can
settle. The deployment script handles this by deploying the registry with the deployer as temporary
owner, authorizing the receipt store, and then transferring registry ownership to
`PROTOCOL_OWNER`.

## Listing Modes

Every listing is created in one of two explicit modes, chosen at `createListing` time
via the `ListingMode` argument and immutable for the lifetime of the listing. The mode
is a deliberate protocol design choice — it decides up front how a listing may be
purchased, rather than leaving that to depend on which function a buyer happens to call.

| Mode | `unitPrice` | Direct `purchaseReceipt` | Signed `purchaseSignedReceipt` |
| --- | --- | --- | --- |
| `PublicFixedPrice` | required, within bounds | allowed | allowed |
| `SignedQuoteOnly` | must be `0` | reverts `ListingRequiresSignedQuote` | required |

- **`PublicFixedPrice`** — public direct checkout at the listing's on-chain `unitPrice`. It *also* accepts seller-authorized signed quotes, which is what enables buyer-bound payment links, metadata-bound checkout, dynamic pricing, discounts, integrator fees, and bot, merchant-backend, or AI-agent checkout flows on top of a public listing.
- **`SignedQuoteOnly`** — carries no on-chain price (`unitPrice` is `0`) and must be purchased through a seller-authorized EIP-712 quote whose `amount` is validated at purchase time. Direct `purchaseReceipt` reverts with `ListingRequiresSignedQuote`.

The protocol only enforces *whether* a signed quote is required. Who issues that quote —
seller wallet, backend, bot, or dashboard — is an application-layer concern.

The mode cannot be changed after creation; v1 has no `setListingMode`. To move a product
to a different mode, deactivate the listing with `setListingActive(listingId, false)` and
create a new one.

For production checkout/payment-link flows, prefer signed quotes.

### `purchaseReceipt(listingId, purchaseRef, amount)`

- Direct purchase path for `PublicFixedPrice` listings only; a `SignedQuoteOnly` listing reverts with `ListingRequiresSignedQuote`.
- The buyer passes the exact `amount` they expect to pay; the contract reverts with `PriceMismatch` if the listing's `unitPrice` differs in either direction.
- Listing prices are immutable after `createListing`, so the price the buyer asserts is the price the buyer pays.
- Does not bind the buyer before submission.
- Anyone who submits a valid unconsumed `purchaseRef` and pays first receives the receipt.
- Suitable for simple public listings where any buyer may purchase.
- Not recommended for seller-issued private payment links, Telegram checkout links, order-specific checkout, buyer-specific checkout, dynamic pricing, or integrator-fee flows.

### `purchaseSignedReceipt(quote, sellerSignature, claimedSigner)`

- Recommended default for production checkout/payment-link flows.
- Works for both listing modes: required for `SignedQuoteOnly`, and also supported on `PublicFixedPrice` listings.
- Uses a seller-authorized EIP-712 quote.
- Binds buyer, listingId, seller, amount, purchaseRef, metadataHash, settlementToken, purchaseRefRegistry, expiry, chain, and contract.
- `buyer` is optional: a non-zero `buyer` must match `msg.sender`, so another wallet cannot redeem the same quote; a zero `buyer` leaves the quote unbound so any wallet may submit and pay (single-use `purchaseRef` still prevents double-redemption).
- Supports dynamic pricing and optional integrator fees.
- Use this for Telegram bot flows, seller-issued order links, private links, custom pricing, and partner or integrator checkouts.

### Fixed-price receipt flow

1. Create a fixed-price listing with `createListing(listingHash, unitPrice, ListingMode.PublicFixedPrice)`. The `unitPrice` is immutable for the lifetime of the listing; to change a product's price, create a new listing.
2. Optionally pause or resume the listing with `setListingActive(listingId, active)`.
3. Agree on a `rawPurchaseRef` off-chain, generate a secret `purchaseRefNonce`, and derive the canonical protocol-scoped `purchaseRef` with `hashPurchaseRef(seller, listingId, rawPurchaseRef, purchaseRefNonce)`, or compute the same hash off-chain.
4. Buyer approves the settlement token and calls `purchaseReceipt(listingId, purchaseRef, amount)`, where `amount` must equal the listing's `unitPrice` exactly.

`purchaseReceipt` is the direct fixed-price purchase path. The buyer-passed `amount` must match `listing.unitPrice`; listing prices are immutable so the price the buyer sees on chain is the price they will pay. The call is public and is not buyer-bound before submission. Anyone who submits a valid unconsumed `purchaseRef` and pays first receives the receipt. It does not support integrator fees. The raw reference stays off-chain; only the derived `bytes32` hash is submitted. For production checkout/payment-link flows, prefer signed quotes.

`listingHash` is an opaque seller-defined metadata commitment. Human-readable product data lives off-chain, for example inside a seller-signed payment link or checkout payload.

### Signed quote receipt flow

Seller Payment Link Mode fits inside the signed quote path and is the recommended default for production checkout flows. The target listing may be either mode: a `SignedQuoteOnly` listing (created with `createListing(listingHash, 0, ListingMode.SignedQuoteOnly)`) restricts the product to this path, while a `PublicFixedPrice` listing also accepts signed quotes for payment-link, dynamic-price, or integrator-fee orders.

1. Seller backend creates an order, generates a short off-chain `rawPurchaseRef`, and derives the protocol-scoped `purchaseRef` hash.
2. Seller optionally authorizes a backend or service key for the listing with `setListingQuoteSigner(listingId, signer, true)`.
3. The seller wallet or an authorized quote signer signs a `SignedReceiptQuote` over `listingId`, `buyer`, `purchaseRef`, `amount`, `metadataHash`, optional `integratorFeeRecipient`, optional `integratorFeeAmount`, seller-declared `issuedAt`, and `expiresAt`; the EIP-712 digest also binds the listing `seller`, the v1 `settlementToken`, and the immutable `purchaseRefRegistry`.
4. Buyer approves the settlement token and calls `purchaseSignedReceipt(quote, sellerSignature, claimedSigner)`. Pass `address(0)` for `claimedSigner` when the listing seller signed; pass the delegate's address when an authorized quote signer signed.
5. The contract checks that `claimedSigner` is the seller or authorized for `quote.listingId`, then verifies the EIP-712 signature against it. Both checks must pass.
6. `ReceiptPurchasedV2` confirms payment, and the seller fulfills the order off-chain.

Signed quotes are the v1 mechanism for dynamic pricing. They do not introduce escrow, delayed settlement, or on-chain price discovery. `issuedAt` is the seller-declared quote issuance timestamp and part of the signed EIP-712 payload. A signed quote is valid only between `issuedAt` and `expiresAt`, and `expiresAt - issuedAt` must not exceed `MAX_QUOTE_TTL`.
`metadataHash` must be non-zero and should commit to the readable off-chain payment-link or checkout metadata the seller intends to authorize.

Use `validateSignedReceiptPurchase(quote, sellerSignature, expectedBuyer, claimedSigner)` when a frontend, bot, or backend wants the same validation path as `purchaseSignedReceipt` without moving funds or creating a receipt. It returns a `SignedReceiptPurchaseValidation` struct.

Use `previewSignedReceiptPurchase(quote)` only for fee math. It does not verify the seller signature, buyer match, expiry, listing active status, or replay state.

Dynamic signed quotes may be signed either by the seller wallet directly or by an authorized quote signer. This lets a seller keep the settlement wallet separate from a backend hot key. The seller authorizes a signer per listing with `setListingQuoteSigner(listingId, signer, true)`, and that signer can create dynamic quotes only for that listing.

Authorized quote signers can issue signed receipt quotes only for listings where they were authorized. Revoke compromised signers immediately with `setListingQuoteSigner(listingId, signer, false)`.

### Integrator fees

Integrator fees are supported only through seller-authorized signed quotes.

This lets marketplaces, bots, checkout frontends, dashboards, and other seller tools monetize without changing seller settlement semantics. The seller or authorized quote signer includes `integratorFeeRecipient` and `integratorFeeAmount` in the signed quote.

A listing-authorized quote signer is trusted to set the full signed quote intent for that listing, including `amount`, `metadataHash`, `buyer`, `purchaseRef`, and optional integrator fee fields. The contract enforces protocol fee caps and quote validity, but it does not know whether a delegated signer chose the seller's intended price, metadata, buyer binding, purchase reference, or integrator fee recipient.

On purchase, the Nota pays:

1. protocol fee
2. integrator fee, if present
3. seller net amount

`receipt.amount` remains the gross amount paid. Fee breakdowns should be indexed from `ProtocolFeePaid` and `IntegratorFeePaid`.

## Signed Quote Typed Data

TypeScript signing shape:

```ts
const domain = {
  name: "NotaReceiptStore",
  version: "2",
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
    { name: "agentId", type: "bytes32" },
    { name: "settlementToken", type: "address" },
    { name: "purchaseRefRegistry", type: "address" },
    { name: "integratorFeeRecipient", type: "address" },
    { name: "integratorFeeAmount", type: "uint256" },
    { name: "issuedAt", type: "uint64" },
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
  issuedAt, // seller-declared quote issuance timestamp
  expiresAt,
};

const signature = await signer.signTypedData(domain, types, message);
```

The `seller` field in typed data is always the listing seller address, even when the signature is produced by an authorized quote signer. `metadataHash` should commit to the readable off-chain payment-link or checkout metadata you want the seller signature to protect. `issuedAt` is seller-declared and signed, and a signed quote is valid only between `issuedAt` and `expiresAt` with `expiresAt - issuedAt <= MAX_QUOTE_TTL`. The contract accepts seller-wallet signatures or authorized quote-signer signatures if authorization exists at purchase time.

The signed EIP-712 type is:

```text
SignedReceiptQuote(uint256 listingId,address seller,address buyer,bytes32 purchaseRef,uint256 amount,bytes32 metadataHash,address settlementToken,address purchaseRefRegistry,address integratorFeeRecipient,uint256 integratorFeeAmount,uint64 issuedAt,uint64 expiresAt)
```

## Quote Signer Security

`setListingQuoteSigner(listingId, signer, true)` authorizes `signer` for one seller-owned listing.

- A listing-authorized quote signer can issue signed receipt quotes only for that listing.
- A signer authorized for one listing cannot sign valid quotes for another listing unless separately authorized there.
- A listing-authorized quote signer can set the full signed quote intent for that listing, including amount, metadataHash, buyer binding, purchaseRef, and optional integrator fee fields.
- Use `isQuoteSignerAuthorized(listingId, signer)` when a frontend, backend, or dashboard needs to treat the seller wallet and delegated signers uniformly.
- Deactivating a listing blocks purchases but does not revoke quote signers; revoke compromised signers explicitly.
- Treat quote signers as hot operational keys.
- Use a dedicated backend signer instead of the seller treasury key as a hot service key.
- Rotate or revoke signers when team members, servers, or environments change.
- Monitor signed quote generation in backend logs.
- If a signer is compromised, revoke it immediately with `setListingQuoteSigner(listingId, signer, false)`.

## Hashes, Metadata, and Privacy

`listingHash`, `purchaseRef`, and `metadataHash` are opaque commitments and identifiers. They are
not encryption. If the underlying raw value is weak, predictable, or guessable, it may still be
guessed off-chain.

Keep human-readable product, order, and customer data off-chain in the seller backend, bot, or
dashboard.

- `listingHash` commits to seller-defined listing metadata without exposing human-readable product data.
- `metadataHash` binds seller-defined payment-link or checkout metadata without revealing it on-chain.
- `purchaseRef` is the protocol-scoped on-chain hash of an off-chain raw operational order reference.

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

### Purchase References

In Receipt Mode, the Nota separates the human-readable off-chain order reference from the
on-chain receipt identifier.

- `rawPurchaseRef` is generated by the seller, bot, frontend, or backend.
- `rawPurchaseRef` stays off-chain.
- `purchaseRef` is the protocol-scoped `bytes32` hash submitted to settlement contracts.
- Canonical replay protection is enforced through `PurchaseRefRegistry.consume(purchaseRef)`, which
  only authorized settlement modules may call.
- `NotaReceiptStore` keeps no per-receipt storage. The `ReceiptPurchasedV2` event is the receipt
  record, and `purchaseRef` is an indexed topic, so resolving a purchase reference to its
  settlement is an `eth_getLogs` filter — no indexer required.
- The canonical hash is scoped by the Nota domain string
  `nota.purchaseRef.receipt.v1`, `chainId`, settlement token
  address, seller address, the raw purchase reference, and the secret purchase ref nonce.

```solidity
purchaseRef = keccak256(abi.encode(
    "nota.purchaseRef.receipt.v1",
    block.chainid,
    address(settlementToken),
    seller,
    rawPurchaseRef,
    purchaseRefNonce
));
```

Because the canonical hash already scopes by chain, settlement token, and seller, the raw
reference should stay short and operational. It should identify the seller-side order in an
external system, not describe the buyer or purchased content.

`listingId` is used only to validate that the listing exists and belongs to the provided seller.
It is not included in the final hash.

Because replay protection is enforced on the final `purchaseRef` hash through a shared
`PurchaseRefRegistry`, the same `purchaseRef` cannot be reused across current or future Nota
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
// rawPurchaseRef is the business identifier; purchaseRefNonce is the secret entropy.
const rawPurchaseRef = `nota_topup_${crypto.randomUUID().replaceAll("-", "")}`;
const purchaseRefNonce = ethers.hexlify(crypto.getRandomValues(new Uint8Array(32))); // secret, 32 bytes
const purchaseRef = await receiptStore.hashPurchaseRef(seller, listingId, rawPurchaseRef, purchaseRefNonce);
```

**The `purchaseRef` commitment binds `(rawPurchaseRef, purchaseRefNonce)`.** `hashPurchaseRef` takes
both a human/business `rawPurchaseRef` and a secret `bytes32 purchaseRefNonce`:

```
purchaseRef = keccak256(abi.encode(
    "nota.purchaseRef.receipt.v1", chainId, settlementToken, seller, rawPurchaseRef, purchaseRefNonce));
```

- `rawPurchaseRef` — the business identifier. Recommended canonical form `<namespace>_<context>_<random>`
  (issuing brand slug, lowercased flow/service id, opaque suffix), e.g.
  `nota_topup_4f8c1d9a2b7e6035a1c4d8e9f0b2a6c3`. With a nonce present, a plain human-readable ref such
  as `invoice-123` is also acceptable.
- `purchaseRefNonce` — a **secret, high-entropy 32-byte salt** generated with a CSPRNG. This is where
  the cryptographic strength comes from: even a guessable `rawPurchaseRef` cannot be brute-forced into
  the on-chain commitment without the nonce.

`(rawPurchaseRef, purchaseRefNonce)` is the **off-chain entitlement bundle** shared seller→buyer; only
the resulting `bytes32 purchaseRef` is ever submitted on-chain. The contract `hashPurchaseRef` is a
convenience view — `purchaseReceipt`/`purchaseSignedReceipt` take the hash directly and never see the
preimage, so format/entropy rules are a convention, not an on-chain rule. The contract only requires
`rawPurchaseRef` to be 1..128 bytes; `purchaseRef` must remain unique across any checkout flow that
shares a `PurchaseRefRegistry`.

Do not use emails, phone numbers, Telegram IDs, usernames, wallet labels, or predictable order
numbers as `rawPurchaseRef`, and do not let it describe the buyer or the purchased content — those
belong off-chain. The secret `purchaseRefNonce` is what keeps the commitment unguessable.

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

`ListingCreated` and `ReceiptPurchasedV2` are the source-of-truth events for listing and receipt
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
- `listingCountBySeller[seller]`, the number of listings a seller currently has active, only to enforce `MAX_LISTINGS_PER_SELLER`

Receipts themselves are not stored on-chain. Writing the six-field receipt struct plus a
seller-scoped lookup mapping cost roughly 155k gas per purchase and nothing on-chain read it:
replay protection lives in `PurchaseRefRegistry`, and discovery comes from events. The
`ReceiptPurchasedV2` event carries every field the struct held; `issuedAt` was always
`block.timestamp`, which the log's own block supplies.

## Signer Verification and Quote Lifetime

Quotes are verified with OpenZeppelin's `SignatureChecker`, which accepts both EOA signatures and
ERC-1271 contract-wallet signatures. This is what allows a seller using a smart wallet — Coinbase
Smart Wallet, Safe — to sign quotes at all. `ECDSA.recover` cannot authenticate a contract account:
there is no key to recover.

Because `SignatureChecker` verifies a *supplied* candidate signer rather than recovering one, and
`authorizedQuoteSigners` cannot be enumerated on-chain, the caller names the signer:

- `claimedSigner = address(0)` — the listing seller signed. The common case.
- `claimedSigner = <delegate>` — a signer authorized for that listing signed.

Naming an address asserts nothing. The address must clear the authorization mapping *and* the
signature must verify against it, so a caller cannot promote an unauthorized signer by pointing at
one.

### Contract-wallet signatures are revocable

This is a change to the quote lifetime model, not just to the verification code.

An ECDSA signature is valid forever once produced. An ERC-1271 signature is only valid while the
wallet still says it is — which is what the `Now` in `isValidSignatureNow` means. **A seller who
rotates the owners of their smart wallet invalidates every quote that wallet has already signed,
including quotes that have not expired.** Outstanding payment links stop working at the moment of
rotation, silently, with no on-chain event marking it.

Practical consequences:

- `expiresAt` is no longer the only thing that can end a quote's life.
- After rotating wallet keys, a seller must re-issue any outstanding payment links.
- A checkout flow should re-run `validateSignedReceiptPurchase` immediately before prompting a
  buyer to pay, rather than trusting a validation performed when the link was generated.

Sellers using an EOA are unaffected.

## Agent Attribution

`SignedReceiptQuote.agentId` is an opaque `bytes32` carried for ERC-8004-style agent attribution
and emitted in `ReceiptPurchasedV2`. It is `bytes32` rather than a typed identifier so the protocol
is not coupled to any registry's ID representation: it may be a registry-scoped identifier or a
hash of one. Zero means unspecified, is always valid, and is what the direct `purchaseReceipt` path
always emits.

The contract performs no validation on `agentId` and resolves it against no registry. Hard-coding a
registry address would create exactly the coupling the opaque type avoids, so resolution is an
off-chain concern.

**`agentId` is seller-attested, not chain-verified.** It records that the seller claims to have
sold to the agent bearing that identifier. The seller signs it, so a buyer cannot attach an agent
identity the seller did not attest to — but the attestation is only as good as the seller's own
verification of the agent's claim. The chain does not check it, and nothing here should be read as
though it does.

The seller signs it for the same reason the seller signs `metadataHash`: the buyer is the agent,
and a self-declared identity is worthless.

## Fee Model

The v1 fee model is immutable at deployment:

- `settlementToken`
- `feeRecipient`
- `protocolFeeBps`

Constraints:

- `protocolFeeBps` is capped at `MAX_PROTOCOL_FEE_BPS = 50` basis points (0.5%)
- `integratorFeeAmount` in signed quotes is capped at `MAX_INTEGRATOR_FEE_BPS = 450` basis points (4.5%) of the quoted `amount`
- combined protocol fee plus integrator fee cannot exceed 5% under these separate caps
- `feeRecipient` must be non-zero when `protocolFeeBps > 0`
- `integratorFeeRecipient` must be the zero address when `integratorFeeAmount = 0`
- `integratorFeeRecipient` must be non-zero when `integratorFeeAmount > 0`
- official v1 deployments are intended for a 6-decimal settlement token such as USDC
- `MIN_PURCHASE_AMOUNT = 1e2` assumes 6 decimals and means 0.0001 USDC
- there is no protocol-level maximum purchase amount in this contract
- large purchases are controlled by seller quote policy, frontend/backend limits, token allowance and balance, and operational risk controls
- deploying with an 18-decimal token changes the practical meaning of the minimum purchase amount and is not recommended unless constants are adjusted in a future version
- for Arbitrum mainnet, use the canonical or native USDC deployment intended by the project
- `settlementToken` should be a standard ERC-20 such as USDC
- fee-on-transfer and rebasing tokens are not supported

There is no dynamic fee mutation in v1.

## Safety Controls

`NotaReceiptStore` is owned and uses `Ownable2Step` for admin transfers.

The owner can independently pause:

- listing creation
- purchases
- quote signer updates

v1 also enforces conservative protocol limits:

- min purchase: 0.0001 USDC (`1e2`) assuming a 6-decimal settlement token
- max quote TTL: 24 hours
- max listings per seller: 500 active at once

`MAX_LISTINGS_PER_SELLER` is a concurrency cap, not a lifetime one. Deactivating a listing with
`setListingActive(listingId, false)` releases its slot, and reactivating reclaims one and re-checks
the cap. A seller who changes prices by superseding listings — the only way to change a price,
since `unitPrice` is immutable — does not permanently spend their budget. The trade is that
reactivating an old listing can fail if the seller has since filled the cap.

### Ownership

`renounceOwnership()` reverts while any pause flag is set — `purchasesPaused`,
`listingCreationPaused`, or `quoteSignerUpdatesPaused`. Only the owner can clear a pause, so
renouncing mid-pause strands the contract in that state permanently, with no recovery path: no
buyer could purchase, no seller could list, or no seller could rotate a compromised quote signer.
Clear the pauses first, then renounce. Renouncing while unpaused is permitted and, as always,
irreversible.
- max quote signers per seller: 3

Integration guide:

- [`docs/receipt-mode-integration.md`](docs/receipt-mode-integration.md)

Measured gas, before and after the storage-free receipt change:

- [`docs/benchmarks.md`](docs/benchmarks.md)

## Contract Surface

Core contract:

- `src/PurchaseRefRegistry.sol`
- `src/NotaReceiptStore.sol`

Key functions:

- `consume`
- `isConsumed`
- `consumedBy`
- `createListing`
- `setListingQuoteSigner`
- `setListingActive`
- `hashPurchaseRef`
- `purchaseReceipt`
- `purchaseSignedReceipt`
- `quotePurchaseReceipt`
- `previewSignedReceiptPurchase`
- `validateSignedReceiptPurchase`
- `hashSignedReceiptQuote`
- `isQuoteSignerAuthorized`

Key events:

- `ListingCreated`
- `ListingStatusChanged`
- `QuoteSignerAuthorizationChanged`
- `ReceiptPurchasedV2`
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

The v1 deploy script deploys `PurchaseRefRegistry` first and then deploys `NotaReceiptStore`
with that registry address wired into the constructor.

Official v1 deployments are intended for a 6-decimal settlement token such as USDC.
`MIN_PURCHASE_AMOUNT = 1e2` assumes 6 decimals and means 0.0001 USDC. The floor is deliberately
low so x402 agent payments, which are typically fractions of a cent, can settle.

Fee rounding at that size favours the seller. Both fees floor-divide and the caps sum to 500 bps,
so `protocolFee + integratorFee` is at most 5% of gross and `sellerNet` is never zero. At the floor
itself a 50 bps protocol fee rounds to zero — it needs `grossAmount >= 200` to reach one base
unit — so on a fee-charging deployment the smallest purchases pay no protocol fee at all.
There is no protocol-level maximum purchase amount in this contract. Large purchases are
controlled by seller quote policy, frontend/backend limits, token allowance and balance, and
operational risk controls.
The deploy script enforces `IERC20Metadata(SETTLEMENT_TOKEN).decimals() == 6`. On Arbitrum
One mainnet (`chainid 42161`) the script additionally pins `SETTLEMENT_TOKEN` to Circle's
canonical native USDC `0xaf88d065e77c8cC2239327C5EDb3A432268e5831` and rejects USDC.e (bridged).

Required envs:

- `RPC_URL`
- `PRIVATE_KEY`
- `SETTLEMENT_TOKEN`
- `FEE_RECIPIENT`
- `PROTOCOL_FEE_BPS` — must equal `EXPECTED_PROTOCOL_FEE_BPS` in `Deploy.s.sol` (currently `50`)

Optional envs:

- `PROTOCOL_OWNER` — override the default owner. If unset (or equal to the deployer), the
  deployer is set as the immediate owner of both contracts in their constructors and the
  script skips `transferOwnership`, so there is no `Ownable2Step` pending-owner window. If
  set to a different address, the registry ownership is queued to that address and the
  target must call `acceptOwnership()` in a separate transaction before it actually owns
  the registry.

`FEE_RECIPIENT` may be the zero address only when `PROTOCOL_FEE_BPS=0`. The fee recipient
is immutable post-deploy — verify the address can receive USDC before broadcasting.

The deploy output logs both:

- `PurchaseRefRegistry`
- `ReceiptStore`

If a future Nota settlement contract must share replay protection with an existing deployment,
it should be deployed against the same `PurchaseRefRegistry` address.

Typical Arbitrum One mainnet flow (solo deployer, deployer == protocol owner):

```bash
export RPC_URL="https://arb1.arbitrum.io/rpc"
export PRIVATE_KEY="0xYOUR_DEPLOYER_KEY"
export SETTLEMENT_TOKEN="0xaf88d065e77c8cC2239327C5EDb3A432268e5831"  # Arbitrum One native USDC
export FEE_RECIPIENT="0xYOUR_FEE_RECIPIENT"                            # separate address, immutable
export PROTOCOL_FEE_BPS="50"
# PROTOCOL_OWNER left unset → defaults to deployer → no pending-owner window

forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC_URL" --broadcast --verify
```

Arbitrum Sepolia flow (testnet, any 6-decimal USDC):

```bash
export RPC_URL="https://your-arbitrum-sepolia-rpc"
export PRIVATE_KEY="0xYOUR_DEPLOYER_KEY"
export SETTLEMENT_TOKEN="0xYOUR_TEST_USDC_ON_SEPOLIA"
export FEE_RECIPIENT="0xYOUR_FEE_RECIPIENT"
export PROTOCOL_FEE_BPS="50"

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


## Scope

Nota v1 is intentionally focused on receipt-mode settlement and off-chain fulfillment.

Future modules should be documented in their own specifications and repositories when they are designed or implemented.
