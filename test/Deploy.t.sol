// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test} from "forge-std/Test.sol";

import {Deploy} from "../script/Deploy.s.sol";
import {PurchaseRefRegistry} from "../src/PurchaseRefRegistry.sol";
import {RevealReceiptStore} from "../src/RevealReceiptStore.sol";

contract DeployMockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

/// @dev Injects deploy config directly instead of going through the environment. `vm.setEnv`
///      writes process-global state that forge does not roll back between test cases, so
///      env-driven deploy tests clobber each other.
contract DeployHarness is Deploy {
    DeployConfig internal injectedConfig;

    function setConfig(DeployConfig memory config) external {
        injectedConfig = config;
    }

    function _readConfig() internal view override returns (DeployConfig memory) {
        return injectedConfig;
    }
}

/// @dev Covers the chain-conditional guards in the deploy script. The Base mainnet cases are the
///      load-bearing ones: the zero protocol fee is a positioning commitment that integrators are
///      supposed to be able to verify on-chain, so the script must refuse to deploy Base with a
///      fee configured, or with a fee destination that would make the commitment ambiguous.
contract DeployTest is Test {
    uint256 internal constant BASE_MAINNET_CHAIN_ID = 8453;
    address internal constant BASE_MAINNET_NATIVE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant BASE_USDBC_BRIDGED = 0xd9aAEc86B65D86f6A7B5B1b0c42FFA531710b6CA;
    uint256 internal constant ARBITRUM_ONE_CHAIN_ID = 42161;
    address internal constant ARBITRUM_ONE_NATIVE_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    uint256 internal constant ARBITRUM_SEPOLIA_CHAIN_ID = 421614;

    uint256 internal constant DEPLOYER_PK = 0xD3910E7;
    string internal constant FEE_MISMATCH_ERROR =
        "PROTOCOL_FEE_BPS does not match the expected fee for this chain  update the constant deliberately";

    DeployHarness internal deployScript;
    address internal deployer;

    function setUp() public {
        deployScript = new DeployHarness();
        deployer = vm.addr(DEPLOYER_PK);

        // Put a 6-decimal token at each address the script pins, so decimals() resolves.
        bytes memory usdcCode = address(new DeployMockUSDC()).code;
        vm.etch(BASE_MAINNET_NATIVE_USDC, usdcCode);
        vm.etch(BASE_USDBC_BRIDGED, usdcCode);
        vm.etch(ARBITRUM_ONE_NATIVE_USDC, usdcCode);

        vm.deal(deployer, 10 ether);
    }

    function _configure(address settlementToken, uint256 feeBps, address feeRecipient) internal {
        deployScript.setConfig(
            Deploy.DeployConfig({
                pk: DEPLOYER_PK,
                settlementToken: settlementToken,
                feeRecipient: feeRecipient,
                protocolOwner: deployer,
                protocolFeeBps: feeBps
            })
        );
    }

    function test_Base_DeploysWithImmutableZeroFeeAndNoFeeRecipient() public {
        vm.chainId(BASE_MAINNET_CHAIN_ID);
        _configure(BASE_MAINNET_NATIVE_USDC, 0, address(0));

        (PurchaseRefRegistry registry, RevealReceiptStore receiptStore) = deployScript.run();

        // The commitment an integrator can read off-chain: no fee, and no destination for one.
        assertEq(receiptStore.PROTOCOL_FEE_BPS(), 0);
        assertEq(receiptStore.FEE_RECIPIENT(), address(0));
        assertEq(address(receiptStore.SETTLEMENT_TOKEN()), BASE_MAINNET_NATIVE_USDC);
        assertTrue(registry.authorizedConsumers(address(receiptStore)));
    }

    function test_Base_RejectsNonZeroProtocolFee() public {
        vm.chainId(BASE_MAINNET_CHAIN_ID);
        _configure(BASE_MAINNET_NATIVE_USDC, 50, address(0xFEE));

        vm.expectRevert(bytes(FEE_MISMATCH_ERROR));
        deployScript.run();
    }

    function test_Base_RejectsFeeRecipientAtZeroFee() public {
        vm.chainId(BASE_MAINNET_CHAIN_ID);
        _configure(BASE_MAINNET_NATIVE_USDC, 0, address(0xFEE));

        vm.expectRevert("Base mainnet: FEE_RECIPIENT must be zero at zero fee");
        deployScript.run();
    }

    function test_Base_RejectsBridgedUSDbC() public {
        vm.chainId(BASE_MAINNET_CHAIN_ID);
        _configure(BASE_USDBC_BRIDGED, 0, address(0));

        vm.expectRevert("Base mainnet: SETTLEMENT_TOKEN must be native USDC");
        deployScript.run();
    }

    /// @dev The Base carve-out must not change what other chains expect.
    function test_ArbitrumOne_StillExpectsLaunchFee() public {
        vm.chainId(ARBITRUM_ONE_CHAIN_ID);
        _configure(ARBITRUM_ONE_NATIVE_USDC, 50, address(0xFEE));

        (, RevealReceiptStore receiptStore) = deployScript.run();

        assertEq(receiptStore.PROTOCOL_FEE_BPS(), 50);
        assertEq(receiptStore.FEE_RECIPIENT(), address(0xFEE));
    }

    function test_ArbitrumOne_RejectsZeroProtocolFee() public {
        vm.chainId(ARBITRUM_ONE_CHAIN_ID);
        _configure(ARBITRUM_ONE_NATIVE_USDC, 0, address(0));

        vm.expectRevert(bytes(FEE_MISMATCH_ERROR));
        deployScript.run();
    }

    /// @dev Testnets keep the launch fee and are not pinned to a specific token address.
    function test_Testnet_KeepsLaunchFeeAndUnpinnedToken() public {
        vm.chainId(ARBITRUM_SEPOLIA_CHAIN_ID);
        address testUsdc = address(new DeployMockUSDC());
        _configure(testUsdc, 50, address(0xFEE));

        (, RevealReceiptStore receiptStore) = deployScript.run();

        assertEq(receiptStore.PROTOCOL_FEE_BPS(), 50);
        assertEq(address(receiptStore.SETTLEMENT_TOKEN()), testUsdc);
    }
}
