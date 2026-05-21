# zkReveal v1

zkReveal v1 is a minimal on-chain receipt and settlement layer for digital sellers.

Buyer pays.  
Seller gets paid.  
Your backend receives a verifiable on-chain purchase receipt.

Receipt Mode lets sellers create fixed-price listings or accept seller-authorized dynamic quotes. The contract settles funds immediately and emits a `ReceiptPurchased` event that seller bots, APIs, dashboards, or indexers can use to fulfill orders off-chain.

v1 is Receipt Mode only.

- v1 is not Delivery Mode
- v1 is not Escrow Mode
- v1 does not support refunds or reclaim flows
- v1 does not support buyer public keys, encrypted payloads, content CIDs, inventory units, or delivery deadlines
- v1 does not do dynamic on-chain pricing, oracle pricing, or marketplace fee routing
- v1 does not expose cross-chain gateway adapter entrypoints

## Product Model

`RevealReceiptStore` is the only required v1 product contract.

### Fixed-price receipt flow

1. Create a fixed-price listing with `createListing(title, resourceId, unitPrice)`.
2. Optionally update the fixed listing price with `setListingPrice(listingId, newUnitPrice)`.
3. Optionally pause or resume the listing with `setListingActive(listingId, active)`.
4. Generate a unique off-chain `purchaseRef` for the buyer or order.
5. Buyer approves the settlement token and calls `purchaseReceipt(listingId, purchaseRef)`.

`purchaseReceipt` is the direct fixed-price purchase path. It does not support integrator fees.

### Signed quote receipt flow

1. Seller backend creates an order and generates a seller-scoped `purchaseRef`.
2. Seller optionally authorizes a backend or service key once with `setQuoteSigner(signer, true)`.
3. The seller wallet or an authorized quote signer signs a `SignedReceiptQuote` with `listingId`, `buyer`, `purchaseRef`, `amount`, `settlementToken`, optional `integratorFeeRecipient`, optional `integratorFeeAmount`, and `expiresAt`.
4. Buyer approves the settlement token and calls `purchaseSignedReceipt(quote, sellerSignature)`.
5. The contract verifies the EIP-712 signature and accepts it when the recovered signer is the seller or a seller-authorized quote signer at purchase time.
6. `ReceiptPurchased` confirms payment, and the seller fulfills the order off-chain.

Signed quotes are the v1 mechanism for dynamic pricing. They do not introduce escrow, delayed settlement, or on-chain price discovery.

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
    { name: "settlementToken", type: "address" },
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
  settlementToken,
  integratorFeeRecipient, // zero address when no integrator fee is used
  integratorFeeAmount, // zero when no integrator fee is used
  expiresAt,
};

const signature = await signer.signTypedData(domain, types, message);
```

The `seller` field in typed data is always the listing seller address, even when the signature is produced by an authorized quote signer. The contract accepts seller-wallet signatures or authorized quote-signer signatures if authorization exists at purchase time.

The signed EIP-712 type is:

```text
SignedReceiptQuote(uint256 listingId,address seller,address buyer,bytes32 purchaseRef,uint256 amount,address settlementToken,address integratorFeeRecipient,uint256 integratorFeeAmount,uint64 expiresAt)
```

## Purchase References

`purchaseRef` is a seller-scoped `bytes32` reference used for replay protection and backend reconciliation.

Do not put raw order IDs, usernames, phone numbers, emails, or private business data on-chain. Generate `purchaseRef` off-chain as an opaque hash-like value and keep the private mapping in your backend.

Example conceptually:

```text
purchaseRef = hash(sellerAddress, internalOrderId, randomNonce)
```

The same `purchaseRef` can be reused by different sellers, but cannot be used twice by the same seller.

## Source of Truth

The `ReceiptPurchased` event is the source of truth for seller bots, backends, dashboards, and indexers.

Backends can reconcile purchases by:

- `seller`
- `purchaseRef`

The contract also stores:

- `receiptIdBySellerAndPurchaseRef[seller][purchaseRef]`
- `receipts[receiptId]`
- `receiptsByBuyer[buyer]`
- `receiptsBySeller[seller]`

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

- title: 96 bytes
- resourceId: 128 bytes
- min purchase: 1 USDC (`1e6`)
- max purchase: 5,000 USDC (`5_000e6`)
- max quote TTL: 24 hours
- max listings per seller: 50
- max quote signers per seller: 3

## Contract Surface

Core contract:

- `src/RevealReceiptStore.sol`

Key functions:

- `createListing`
- `setQuoteSigner`
- `setListingActive`
- `setListingPrice`
- `purchaseReceipt`
- `purchaseSignedReceipt`
- `quotePurchaseReceipt`
- `previewSignedReceiptPurchase`
- `hashSignedReceiptQuote`
- `getReceiptIdBySellerAndPurchaseRef`

Key events:

- `ListingCreated`
- `ListingStatusChanged`
- `ListingPriceChanged`
- `QuoteSignerAuthorizationChanged`
- `ReceiptPurchased`
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

The v1 deploy script deploys only `RevealReceiptStore`.

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

Current Arbitrum Sepolia deployment as of 2026-04-30:

- chain ID: `421614`
- contract: `0x55743A4e0836cc3c3f6189fC19e1e19a7F3c84c8`
- deploy tx: `0xdf54cc481b7992d7b3016dd832384ca63dcbe0eb75b5b5e15a45ab2eaba1bb9a`
- settlement token: `0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d`
- owner: `0xc3549AAc0EB0F3310e116BC72B03B20ae8a1e03e`
- protocol fee bps: `0`

## Roadmap

Future roadmap may include Protected Delivery, Escrow Mode, or gateway adapters for pay-from-other-chain UX, but those are not part of zkReveal v1.

The v1 core is intentionally focused on receipt-mode settlement and off-chain fulfillment.
