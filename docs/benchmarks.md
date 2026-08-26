# Gas Benchmarks

Execution gas for the buyer-facing purchase paths, measured against real Circle USDC on forked
Base and Arbitrum One mainnet.

| | |
|---|---|
| Measured | 2026-08-26 |
| Before | `b62fa02` — receipt storage present, 50 bps launch fee |
| After | `90a0b3e` — receipt storage removed, protocol fee zero |
| Harness | [`test/GasBenchmarkFork.t.sol`](../test/GasBenchmarkFork.t.sol) |

## Shipping configuration

Base mainnet, zero protocol fee, no receipt storage, `purchaseReceipt` (direct fixed-price):

- **128,892 gas** — first sale, payout recipients' balance slots cold and zero
- **111,792 gas** — steady state, recipients already hold USDC
- **59–60% reduction** against the original 50 bps receipt-storing build

## Base and Arbitrum are identical

Every figure below was measured twice — once on a Base fork, once on an Arbitrum One fork — and
the two agree to the gas across all 24 measurements. Both chains run Circle's native USDC, and
EVM execution gas is the same instruction set either way.

Choosing Base over Arbitrum does not change what a receipt *costs to execute*. It changes what
that gas is priced at. The table below therefore covers both chains.

## Full matrix

Two variables, both real: the protocol fee, and whether the payout recipients' balance slots are
already warm. `cold` is a first sale; `warm` is the steady state and the normal case.

| Path | Fee | Slots | Before | After | Saved |
|---|---|---|---:|---:|---:|
| `purchaseReceipt` | 0 bps | cold | 284,239 | **128,892** | 155,347 (54.7%) |
| `purchaseReceipt` | 0 bps | warm | 267,139 | **111,792** | 155,347 (58.2%) |
| `purchaseReceipt` | 50 bps | cold | 314,115 | 158,768 | 155,347 (49.5%) |
| `purchaseReceipt` | 50 bps | warm | 279,915 | 124,568 | 155,347 (55.5%) |
| `purchaseSignedReceipt` | 0 bps | cold | 288,555 | **133,236** | 155,319 (53.8%) |
| `purchaseSignedReceipt` | 0 bps | warm | 271,455 | **116,136** | 155,319 (57.2%) |
| `purchaseSignedReceipt` | 50 bps | cold | 318,431 | 163,112 | 155,319 (48.8%) |
| `purchaseSignedReceipt` | 50 bps | warm | 284,231 | 128,912 | 155,319 (54.6%) |
| … + integrator fee | 0 bps | cold | 318,803 | **163,484** | 155,319 (48.7%) |
| … + integrator fee | 0 bps | warm | 284,603 | **129,284** | 155,319 (54.6%) |
| … + integrator fee | 50 bps | cold | 348,679 | 193,360 | 155,319 (44.5%) |
| … + integrator fee | 50 bps | warm | 297,379 | 142,060 | 155,319 (52.2%) |

Bold rows are the zero-fee configuration Base deploys.

## What each change bought

The two savings are independent and additive; the harness varies one axis at a time, so each is
measurable on its own.

| Removed | Condition | Gas | Why |
|---|---|---:|---|
| Receipt storage | every configuration | 155,347 | Six cold slots for the struct, one for the lookup mapping |
| Receipt storage | signed-quote paths | 155,319 | The same seven slots; 28 gas differs elsewhere in the path |
| Protocol fee leg | cold recipient | 29,876 | Transfer writes a zero balance slot, plus one log |
| Protocol fee leg | warm recipient | 12,776 | Fees have accumulated, so the slot is already non-zero |

The fee-leg split matters when quoting this. A fee recipient that has ever been paid holds a
non-zero balance forever after, so the steady-state saving is **12,776** — well under half the
cold-start figure a first-transaction benchmark reports. Quoting the cold number alone overstates
it by more than 2×.

## Findings

**Max approval saves nothing on USDC.** `purchaseReceipt` and `purchaseReceipt.maxApproval` are
byte-identical at every configuration (128,892 and 128,892 at the shipping config). Circle's USDC
does not special-case an infinite allowance, so the allowance slot is written either way. Any
integrator guidance suggesting "approve max to save gas" is wrong for this token.

**The storage saving is chain-independent.** 155,347 gas on Base, 155,347 on Arbitrum, in all four
fee/warmth combinations. SSTORE pricing is protocol-level, so the figure travels to any EVM chain.

**Supporting operations.** `createListing` costs 107,553 and the buyer's one-time `USDC.approve`
costs 36,990. Both are unaffected by this work and identical across chains.

## Method and limits

**Measurement.** Gas is read with `gasleft()` around the call, after `vm.cool()` resets every
touched account to cold, so each measurement reflects a real transaction rather than state already
warmed by test setup.

**Before figures** were produced by running the same harness against `b62fa02` in a throwaway git
worktree, not reconstructed by arithmetic.

**The fork block is not pinned.** `vm.createSelectFork` takes chain head at run time — Base
≈ 50,492,752 and Arbitrum ≈ 498,688,331 for this run. Figures drift slightly on a later run. Pin a
block before quoting these publicly so a reader can reproduce them exactly.

**L2 execution gas only.** These are EVM execution gas, which is what the contract controls.
Neither the L1 data fee nor Arbitrum's calldata surcharge is included, and both are a real part of
what a buyer pays.

**Price snapshot.** At run time Base was 0.006 gwei and Arbitrum 0.020388 gwei, putting the
128,892-gas shipping purchase at roughly 0.00000077 ETH on Base and 0.0000026 ETH on Arbitrum —
execution only, and volatile. Illustrative, not a quotable price.

**Endpoints.** Public RPCs `mainnet.base.org` and `arb1.arbitrum.io/rpc`. No credentials involved.

## Reproducing

The fork suites skip when their RPC variable is unset, so `forge test` stays green offline.

```bash
BASE_RPC_URL=<endpoint> FOUNDRY_PROFILE=ci forge test --match-contract BaseGasBenchmark -vv
```

```bash
ARBITRUM_RPC_URL=<endpoint> FOUNDRY_PROFILE=ci forge test --match-contract ArbitrumGasBenchmark -vv
```

Reported lines are prefixed `GASBENCH|`, labelled `<chain>.<firstSale|repeatSale>[.zeroFee]`.
Difference the `.zeroFee` suites against their 50 bps counterparts to price the protocol-fee leg.
