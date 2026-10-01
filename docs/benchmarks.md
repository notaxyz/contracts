# Gas Benchmarks

Execution gas for the buyer-facing purchase paths and seller attestation, measured against real
Circle USDC on forked Base and Arbitrum One mainnet.

| | |
|---|---|
| Measured | 2026-10-01 (After); Before figures from 2026-08-27, not re-measured |
| Before | `b62fa02` — receipt storage present, 50 bps launch fee, ECDSA-only signers |
| After | `6d642ef` — storage-free receipts, zero fee, ERC-1271 signers, `agentId`, `attestReceipt` |
| Harness | [`test/GasBenchmarkFork.t.sol`](../test/GasBenchmarkFork.t.sol) |

## Shipping configuration

Base mainnet, zero protocol fee, no receipt storage, `purchaseReceipt` (direct fixed-price):

- **129,664 gas** — first sale, payout recipients' balance slots cold and zero
- **112,564 gas** — steady state, recipients already hold USDC
- **~59% reduction** against the original 50 bps receipt-storing build

For the signed-quote path, which is the recommended production flow: **138,439** first sale and
**121,339** steady state.

Seller attestation (`attestReceipt`) costs **54,826 gas**, about 42% of a first-sale direct
purchase at zero fee (129,664) — under half. Recording a sale paid elsewhere is cheap enough to do
once per call, which is what makes per-call attestation viable at agent-commerce prices. The ratio
is execution gas only; the per-transaction costs below apply to both calls and narrow it.

## Base and Arbitrum are identical

Every figure below was measured twice — once on a Base fork, once on an Arbitrum One fork — and the
two agree to the gas across all measurements. Both chains run Circle's native USDC, and EVM
execution gas is the same instruction set either way.

Choosing Base over Arbitrum does not change what a receipt *costs to execute*. It changes what that
gas is priced at. The table below therefore covers both chains.

## Full matrix

Two variables, both real: the protocol fee, and whether the payout recipients' balance slots are
already warm. `cold` is a first sale; `warm` is the steady state and the normal case.

| Path | Fee | Slots | Before | After | Saved |
|---|---|---|---:|---:|---:|
| `purchaseReceipt` | 0 bps | cold | 284,239 | **129,664** | 154,575 (54.4%) |
| `purchaseReceipt` | 0 bps | warm | 267,139 | **112,564** | 154,575 (57.9%) |
| `purchaseReceipt` | 50 bps | cold | 314,115 | 159,540 | 154,575 (49.2%) |
| `purchaseReceipt` | 50 bps | warm | 279,915 | 125,340 | 154,575 (55.2%) |
| `purchaseSignedReceipt` | 0 bps | cold | 288,555 | **138,439** | 150,116 (52.0%) |
| `purchaseSignedReceipt` | 0 bps | warm | 271,455 | **121,339** | 150,116 (55.3%) |
| `purchaseSignedReceipt` | 50 bps | cold | 318,431 | 168,315 | 150,116 (47.1%) |
| `purchaseSignedReceipt` | 50 bps | warm | 284,231 | 134,115 | 150,116 (52.8%) |
| … + integrator fee | 0 bps | cold | 318,803 | **168,687** | 150,116 (47.1%) |
| … + integrator fee | 0 bps | warm | 284,603 | **134,487** | 150,116 (52.7%) |
| … + integrator fee | 50 bps | cold | 348,679 | 198,563 | 150,116 (43.1%) |
| … + integrator fee | 50 bps | warm | 297,379 | 147,263 | 150,116 (50.5%) |
| `attestReceipt` | any | any | — | **54,826** | — |

Bold rows are the zero-fee configuration Base deploys.

`attestReceipt` is one row because it is identical in all eight suites. It moves no USDC, so
prefunded recipient balances are irrelevant and no fee leg runs; neither axis touches it. It did
not exist at `b62fa02`.

**Why the direct path moved by 22.** Against `8c2636c`, `purchaseReceipt` is 22 gas cheaper in
every fee/warmth combination and `createListing` is 22 cheaper; the signed paths did not move. The
only code change since `8c2636c` is the added `attestReceipt` function and its event. Adding a
selector re-partitions solc's function dispatcher: `purchaseReceipt` now reaches its body after 4
selector comparisons instead of 5, and `createListing` after 3 instead of 4, while
`purchaseSignedReceipt` stays at 4. One comparison (`DUP1 PUSH4 EQ PUSH2 JUMPI`) is 22 gas. This is
a compiler layout artifact, not a change to either function.

## What each change cost or bought

The savings are independent and additive; the harness varies one axis at a time, so each is
measurable on its own.

| Change | Condition | Gas | Why |
|---|---|---:|---|
| Removed receipt storage | direct path | −155,347 | Six cold slots for the struct, one for the lookup mapping |
| Removed receipt storage | signed paths | −155,319 | The same seven slots |
| Removed protocol fee leg | cold recipient | −29,876 | Transfer writes a zero balance slot, plus one log |
| Removed protocol fee leg | warm recipient | −12,776 | Fees have accumulated, so the slot is already non-zero |
| Added `agentId` | all paths | +794 | One more event data word, plus its memory expansion |
| Added ERC-1271 + `claimedSigner` | signed paths | +4,409 | `SignatureChecker` instead of `ECDSA.recover`, the authorization lookup, and `agentId` in the digest |

Net of the additions, the storage removal is still worth **154,553** on the direct path and
**150,116** on the signed paths, as measured at `8c2636c`. The matrix's 154,575 on the direct path
includes the further −22 from dispatch reordering described above.

The fee-leg split matters when quoting this. A fee recipient that has ever been paid holds a
non-zero balance forever after, so the steady-state saving is **12,776** — well under half the
cold-start figure a first-transaction benchmark reports. Quoting the cold number alone overstates it
by more than 2×.

Accepting smart-wallet sellers costs **4,409 gas** on the signed path, about 3% of that path's
total. That is the price of Coinbase Smart Wallet sellers being able to sign quotes at all.

## Findings

**Max approval saves nothing on USDC.** `purchaseReceipt` and `purchaseReceipt.maxApproval` are
byte-identical at every configuration (129,664 and 129,664 at the shipping config). Circle's USDC
does not special-case an infinite allowance, so the allowance slot is written either way. Any
integrator guidance suggesting "approve max to save gas" is wrong for this token.

**The storage saving is chain-independent.** Identical on Base and Arbitrum in all four fee/warmth
combinations. SSTORE pricing is protocol-level, so the figure travels to any EVM chain.

**The figures are reproducible across chain heads.** The `b62fa02` baseline was measured twice, in
separate sessions against different chain heads, and every purchase figure came back identical. The
harness `deal`s balances and `vm.cool`s every touched account, so the measured path does not depend
on ambient chain state.

**Supporting operations.** `createListing` costs 107,575 (up 33 from the concurrency-cap change,
then down 22 from dispatch reordering when `attestReceipt` was added) and
the buyer's one-time `USDC.approve` costs 36,990, unchanged and identical across chains.

## Method and limits

**Measurement.** Gas is read with `gasleft()` around the call, after `vm.cool()` resets every
touched account to cold, so each measurement reflects a real transaction rather than state already
warmed by test setup.

**Before figures** were produced by running the same harness against `b62fa02` in a throwaway git
worktree, not reconstructed by arithmetic.

**The fork block is not pinned.** `vm.createSelectFork` takes chain head at run time — Base
≈ 50,492,752 and Arbitrum ≈ 498,688,331 when these were first measured, and Base
52,039,929–52,039,934 and Arbitrum 510,703,978–510,704,011 for the current run. In practice the figures reproduced exactly across both, but nothing guarantees that
for an arbitrary future head. Pin a block if these need to be reproducible by a third party on
demand.

**L2 execution gas only.** These are EVM execution gas, which is what the contract controls. Neither
the L1 data fee nor Arbitrum's calldata surcharge is included, and both are a real part of what a
buyer pays. The same holds for `attestReceipt`: 54,826 is execution only, and a seller's
attestation transaction also pays the intrinsic and data costs.

**Price snapshot.** Base fees read at chain head immediately after the 2026-10-01 run: Base 0.005
gwei, Arbitrum 0.020068 gwei. At those, the 129,664-gas shipping purchase is roughly
0.00000065 ETH on Base and 0.0000026 ETH on Arbitrum, and the 54,826-gas attestation roughly
0.00000027 ETH on Base and 0.0000011 ETH on Arbitrum — execution only, and volatile. Illustrative,
not a quotable price.

**Endpoints.** Public RPCs `mainnet.base.org` and `arb1.arbitrum.io/rpc`. No credentials involved.

## Reproducing

The fork suites skip when their RPC variable is unset, so `forge test` stays green offline.

```bash
BASE_RPC_URL=<endpoint> ARBITRUM_RPC_URL=<endpoint> FOUNDRY_PROFILE=ci forge test --match-path test/GasBenchmarkFork.t.sol -vv
```

Reported lines are prefixed `GASBENCH|`, labelled `<chain>.<firstSale|repeatSale>[.zeroFee]`.
Difference the `.zeroFee` suites against their 50 bps counterparts to price the protocol-fee leg.
