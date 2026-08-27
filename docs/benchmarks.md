# Gas Benchmarks

Execution gas for the buyer-facing purchase paths, measured against real Circle USDC on forked
Base and Arbitrum One mainnet.

| | |
|---|---|
| Measured | 2026-08-27 |
| Before | `b62fa02` — receipt storage present, 50 bps launch fee, ECDSA-only signers |
| After | `8c2636c` — storage-free receipts, zero fee, ERC-1271 signers, `agentId` |
| Harness | [`test/GasBenchmarkFork.t.sol`](../test/GasBenchmarkFork.t.sol) |

## Shipping configuration

Base mainnet, zero protocol fee, no receipt storage, `purchaseReceipt` (direct fixed-price):

- **129,686 gas** — first sale, payout recipients' balance slots cold and zero
- **112,586 gas** — steady state, recipients already hold USDC
- **~59% reduction** against the original 50 bps receipt-storing build

For the signed-quote path, which is the recommended production flow: **138,439** first sale and
**121,339** steady state.

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
| `purchaseReceipt` | 0 bps | cold | 284,239 | **129,686** | 154,553 (54.4%) |
| `purchaseReceipt` | 0 bps | warm | 267,139 | **112,586** | 154,553 (57.9%) |
| `purchaseReceipt` | 50 bps | cold | 314,115 | 159,562 | 154,553 (49.2%) |
| `purchaseReceipt` | 50 bps | warm | 279,915 | 125,362 | 154,553 (55.2%) |
| `purchaseSignedReceipt` | 0 bps | cold | 288,555 | **138,439** | 150,116 (52.0%) |
| `purchaseSignedReceipt` | 0 bps | warm | 271,455 | **121,339** | 150,116 (55.3%) |
| `purchaseSignedReceipt` | 50 bps | cold | 318,431 | 168,315 | 150,116 (47.1%) |
| `purchaseSignedReceipt` | 50 bps | warm | 284,231 | 134,115 | 150,116 (52.8%) |
| … + integrator fee | 0 bps | cold | 318,803 | **168,687** | 150,116 (47.1%) |
| … + integrator fee | 0 bps | warm | 284,603 | **134,487** | 150,116 (52.7%) |
| … + integrator fee | 50 bps | cold | 348,679 | 198,563 | 150,116 (43.1%) |
| … + integrator fee | 50 bps | warm | 297,379 | 147,263 | 150,116 (50.5%) |

Bold rows are the zero-fee configuration Base deploys.

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
**150,116** on the signed paths.

The fee-leg split matters when quoting this. A fee recipient that has ever been paid holds a
non-zero balance forever after, so the steady-state saving is **12,776** — well under half the
cold-start figure a first-transaction benchmark reports. Quoting the cold number alone overstates it
by more than 2×.

Accepting smart-wallet sellers costs **4,409 gas** on the signed path, about 3% of that path's
total. That is the price of Coinbase Smart Wallet sellers being able to sign quotes at all.

## Findings

**Max approval saves nothing on USDC.** `purchaseReceipt` and `purchaseReceipt.maxApproval` are
byte-identical at every configuration (129,686 and 129,686 at the shipping config). Circle's USDC
does not special-case an infinite allowance, so the allowance slot is written either way. Any
integrator guidance suggesting "approve max to save gas" is wrong for this token.

**The storage saving is chain-independent.** Identical on Base and Arbitrum in all four fee/warmth
combinations. SSTORE pricing is protocol-level, so the figure travels to any EVM chain.

**The figures are reproducible across chain heads.** The `b62fa02` baseline was measured twice, in
separate sessions against different chain heads, and every purchase figure came back identical. The
harness `deal`s balances and `vm.cool`s every touched account, so the measured path does not depend
on ambient chain state.

**Supporting operations.** `createListing` costs 107,597 (up 33 from the concurrency-cap change) and
the buyer's one-time `USDC.approve` costs 36,990, unchanged and identical across chains.

## Method and limits

**Measurement.** Gas is read with `gasleft()` around the call, after `vm.cool()` resets every
touched account to cold, so each measurement reflects a real transaction rather than state already
warmed by test setup.

**Before figures** were produced by running the same harness against `b62fa02` in a throwaway git
worktree, not reconstructed by arithmetic.

**The fork block is not pinned.** `vm.createSelectFork` takes chain head at run time — Base
≈ 50,492,752 and Arbitrum ≈ 498,688,331 when these were first measured, and later heads for the
current run. In practice the figures reproduced exactly across both, but nothing guarantees that
for an arbitrary future head. Pin a block if these need to be reproducible by a third party on
demand.

**L2 execution gas only.** These are EVM execution gas, which is what the contract controls. Neither
the L1 data fee nor Arbitrum's calldata surcharge is included, and both are a real part of what a
buyer pays.

**Price snapshot.** At the time of measurement Base was 0.006 gwei and Arbitrum 0.020388 gwei,
putting the 129,686-gas shipping purchase at roughly 0.00000078 ETH on Base and 0.0000026 ETH on
Arbitrum — execution only, and volatile. Illustrative, not a quotable price.

**Endpoints.** Public RPCs `mainnet.base.org` and `arb1.arbitrum.io/rpc`. No credentials involved.

## Reproducing

The fork suites skip when their RPC variable is unset, so `forge test` stays green offline.

```bash
BASE_RPC_URL=<endpoint> ARBITRUM_RPC_URL=<endpoint> FOUNDRY_PROFILE=ci forge test --match-path test/GasBenchmarkFork.t.sol -vv
```

Reported lines are prefixed `GASBENCH|`, labelled `<chain>.<firstSale|repeatSale>[.zeroFee]`.
Difference the `.zeroFee` suites against their 50 bps counterparts to price the protocol-fee leg.
