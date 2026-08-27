// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PurchaseRefRegistry} from "../src/PurchaseRefRegistry.sol";
import {NotaReceiptStore} from "../src/NotaReceiptStore.sol";

/// @dev Measures execution gas for the two buyer-facing purchase paths against real mainnet
///      USDC on a forked L2. Run with an RPC for the target chain; see the concrete
///      per-chain subclasses at the bottom.
///
///      Each concrete suite varies two axes, so the reported numbers can be differenced:
///        - protocol fee: 50 bps (`PROTOCOL_FEE_BPS`) vs 0 bps (`.zeroFee` labels). The delta is
///          the cost of the protocol-fee leg: one settlement-token `safeTransfer` plus one
///          `ProtocolFeePaid` log.
///        - recipient funding: `firstSale` leaves seller / fee recipient / integrator balance
///          slots cold and zero; `repeatSale` pre-funds them, which is the steady state and
///          turns each payout SSTORE from zero->non-zero into non-zero->non-zero.
///
///      Suites self-skip when their RPC env var is unset, so `forge test` stays green offline.
abstract contract GasBenchmarkFork is Test {
    uint256 internal constant SELLER_PK = 0xA11CE;
    uint16 internal constant PROTOCOL_FEE_BPS = 50;

    IERC20 internal usdc;
    PurchaseRefRegistry internal registry;
    NotaReceiptStore internal store;

    address internal seller;
    address internal buyer = address(0xB0B);
    address internal feeRecipient = address(0xFEE);
    address internal integrator = address(0x1417E);
    address internal owner = address(0x0E1E4);

    uint256 internal constant PRICE = 100_000_000; // 100 USDC
    bytes32 internal constant LISTING_HASH = keccak256("gas-benchmark-listing");
    bytes32 internal constant METADATA_HASH = keccak256("gas-benchmark-metadata");

    function _usdc() internal view virtual returns (address);
    function _rpcEnvVar() internal pure virtual returns (string memory);
    function _label() internal pure virtual returns (string memory);

    /// @dev Set true to pre-fund seller / fee recipient so their USDC balance slots are already
    ///      non-zero (the steady-state "repeat sale" case).
    bool internal prefundRecipients;

    /// @dev Protocol fee the store under measurement is constructed with. Zero-fee suites set
    ///      this to 0 before `super.setUp()` so the fee leg is skipped entirely.
    uint16 internal protocolFeeBps = PROTOCOL_FEE_BPS;

    function setUp() public virtual {
        string memory rpcUrl = vm.envOr(_rpcEnvVar(), string(""));
        if (bytes(rpcUrl).length == 0) {
            // No RPC configured for this chain: skip rather than fail the offline suite.
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpcUrl);

        usdc = IERC20(_usdc());
        seller = vm.addr(SELLER_PK);

        registry = new PurchaseRefRegistry(address(this));
        store = new NotaReceiptStore(address(usdc), address(registry), feeRecipient, protocolFeeBps, owner);
        registry.setConsumerAuthorization(address(store), true);

        deal(address(usdc), buyer, 1_000_000_000, true);
        if (prefundRecipients) {
            deal(address(usdc), seller, 1_000_000, true);
            deal(address(usdc), feeRecipient, 1_000_000, true);
            deal(address(usdc), integrator, 1_000_000, true);
        }

        vm.prank(seller);
        store.createListing(LISTING_HASH, PRICE, NotaReceiptStore.ListingMode.PublicFixedPrice);
    }

    /// @dev Reset every account the purchase touches to cold so the measurement reflects a real
    ///      transaction rather than state already warmed by test setup.
    function _coolAll() internal {
        vm.cool(address(usdc));
        vm.cool(address(store));
        vm.cool(address(registry));
        vm.cool(seller);
        vm.cool(buyer);
        vm.cool(feeRecipient);
        vm.cool(integrator);
    }

    function _approve(uint256 amount) internal {
        vm.prank(buyer);
        usdc.approve(address(store), amount);
    }

    function _report(string memory name, uint256 gasUsed) internal pure {
        console2.log(string.concat("GASBENCH|", _label(), "|", name, "|"), gasUsed);
    }

    function _quote(bytes32 ref, address integratorRecipient, uint256 integratorFee)
        internal
        view
        returns (NotaReceiptStore.SignedReceiptQuote memory quote)
    {
        quote = NotaReceiptStore.SignedReceiptQuote({
            listingId: 1,
            buyer: buyer,
            purchaseRef: ref,
            amount: PRICE,
            metadataHash: METADATA_HASH,
            agentId: bytes32(0),
            integratorFeeRecipient: integratorRecipient,
            integratorFeeAmount: integratorFee,
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + 1 hours)
        });
    }

    function _sign(NotaReceiptStore.SignedReceiptQuote memory quote) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SELLER_PK, store.hashSignedReceiptQuote(quote));
        return abi.encodePacked(r, s, v);
    }

    function test_gas_protocolFeeBps() public view {
        _report("config.protocolFeeBps", protocolFeeBps);
    }

    function test_gas_purchaseReceipt() public {
        _approve(PRICE);
        _coolAll();

        vm.prank(buyer);
        uint256 g0 = gasleft();
        store.purchaseReceipt(1, keccak256("ref-direct"), PRICE);
        uint256 used = g0 - gasleft();

        _report("purchaseReceipt", used);
    }

    function test_gas_purchaseReceipt_maxApproval() public {
        _approve(type(uint256).max);
        _coolAll();

        vm.prank(buyer);
        uint256 g0 = gasleft();
        store.purchaseReceipt(1, keccak256("ref-direct-max"), PRICE);
        uint256 used = g0 - gasleft();

        _report("purchaseReceipt.maxApproval", used);
    }

    function test_gas_purchaseSignedReceipt() public {
        NotaReceiptStore.SignedReceiptQuote memory quote = _quote(keccak256("ref-signed"), address(0), 0);
        bytes memory sig = _sign(quote);
        _approve(PRICE);
        _coolAll();

        vm.prank(buyer);
        uint256 g0 = gasleft();
        store.purchaseSignedReceipt(quote, sig, address(0));
        uint256 used = g0 - gasleft();

        _report("purchaseSignedReceipt", used);
    }

    function test_gas_purchaseSignedReceipt_withIntegratorFee() public {
        NotaReceiptStore.SignedReceiptQuote memory quote =
            _quote(keccak256("ref-signed-integrator"), integrator, 1_000_000);
        bytes memory sig = _sign(quote);
        _approve(PRICE);
        _coolAll();

        vm.prank(buyer);
        uint256 g0 = gasleft();
        store.purchaseSignedReceipt(quote, sig, address(0));
        uint256 used = g0 - gasleft();

        _report("purchaseSignedReceipt.integratorFee", used);
    }

    function test_gas_approve() public {
        _coolAll();
        vm.prank(buyer);
        uint256 g0 = gasleft();
        usdc.approve(address(store), PRICE);
        uint256 used = g0 - gasleft();

        _report("usdc.approve", used);
    }

    function test_gas_createListing() public {
        _coolAll();
        vm.prank(seller);
        uint256 g0 = gasleft();
        store.createListing(keccak256("listing-2"), PRICE, NotaReceiptStore.ListingMode.PublicFixedPrice);
        uint256 used = g0 - gasleft();

        _report("createListing", used);
    }
}

// -----------------------------------------------------------------------------
// Base
// -----------------------------------------------------------------------------

abstract contract BaseChainBenchmark is GasBenchmarkFork {
    function _usdc() internal pure override returns (address) {
        return 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    }

    function _rpcEnvVar() internal pure override returns (string memory) {
        return "BASE_RPC_URL";
    }
}

contract BaseGasBenchmark is BaseChainBenchmark {
    function _label() internal pure override returns (string memory) {
        return "base.firstSale";
    }
}

contract BaseGasBenchmarkRepeat is BaseChainBenchmark {
    function setUp() public override {
        prefundRecipients = true;
        super.setUp();
    }

    function _label() internal pure override returns (string memory) {
        return "base.repeatSale";
    }
}

contract BaseGasBenchmarkZeroFee is BaseChainBenchmark {
    function setUp() public override {
        protocolFeeBps = 0;
        super.setUp();
    }

    function _label() internal pure override returns (string memory) {
        return "base.firstSale.zeroFee";
    }
}

contract BaseGasBenchmarkZeroFeeRepeat is BaseChainBenchmark {
    function setUp() public override {
        prefundRecipients = true;
        protocolFeeBps = 0;
        super.setUp();
    }

    function _label() internal pure override returns (string memory) {
        return "base.repeatSale.zeroFee";
    }
}

// -----------------------------------------------------------------------------
// Arbitrum One (live v1 comparison)
// -----------------------------------------------------------------------------

abstract contract ArbitrumChainBenchmark is GasBenchmarkFork {
    function _usdc() internal pure override returns (address) {
        return 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    }

    function _rpcEnvVar() internal pure override returns (string memory) {
        return "ARBITRUM_RPC_URL";
    }
}

contract ArbitrumGasBenchmark is ArbitrumChainBenchmark {
    function _label() internal pure override returns (string memory) {
        return "arbitrum.firstSale";
    }
}

contract ArbitrumGasBenchmarkRepeat is ArbitrumChainBenchmark {
    function setUp() public override {
        prefundRecipients = true;
        super.setUp();
    }

    function _label() internal pure override returns (string memory) {
        return "arbitrum.repeatSale";
    }
}

contract ArbitrumGasBenchmarkZeroFee is ArbitrumChainBenchmark {
    function setUp() public override {
        protocolFeeBps = 0;
        super.setUp();
    }

    function _label() internal pure override returns (string memory) {
        return "arbitrum.firstSale.zeroFee";
    }
}

contract ArbitrumGasBenchmarkZeroFeeRepeat is ArbitrumChainBenchmark {
    function setUp() public override {
        prefundRecipients = true;
        protocolFeeBps = 0;
        super.setUp();
    }

    function _label() internal pure override returns (string memory) {
        return "arbitrum.repeatSale.zeroFee";
    }
}
