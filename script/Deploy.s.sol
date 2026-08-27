// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PurchaseRefRegistry} from "../src/PurchaseRefRegistry.sol";
import {NotaReceiptStore} from "../src/NotaReceiptStore.sol";

contract Deploy is Script {
    uint256 internal constant MAX_PROTOCOL_FEE_BPS = 50;
    /// @dev Launch fee for every chain except Base mainnet, which is pinned to zero below.
    ///      Update this constant deliberately when the launch fee changes.
    uint256 internal constant EXPECTED_PROTOCOL_FEE_BPS = 50;
    /// @dev Base mainnet launches with a zero protocol fee, immutable in the constructor: the
    ///      receipt path is free and cannot be switched to a fee later, because neither
    ///      PROTOCOL_FEE_BPS nor FEE_RECIPIENT has a setter. Integrators are meant to be able to
    ///      verify that by reading the deployed contract, so this is enforced at the deploy
    ///      boundary rather than left to the operator's env file. If a fee is ever right it
    ///      belongs on the reconciliation API, not on settlement.
    uint256 internal constant BASE_MAINNET_EXPECTED_PROTOCOL_FEE_BPS = 0;
    /// @dev Receipt settlement assumes a 6-decimal token such as USDC.
    uint8 internal constant EXPECTED_SETTLEMENT_TOKEN_DECIMALS = 6;
    /// @dev Arbitrum One mainnet chain id.
    uint256 internal constant ARBITRUM_ONE_CHAIN_ID = 42161;
    /// @dev Circle's native USDC on Arbitrum One. USDC.e (bridged) is intentionally not accepted.
    address internal constant ARBITRUM_ONE_NATIVE_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    /// @dev Base mainnet chain id.
    uint256 internal constant BASE_MAINNET_CHAIN_ID = 8453;
    /// @dev Circle's native USDC on Base. USDbC (bridged) is intentionally not accepted.
    address internal constant BASE_MAINNET_NATIVE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    /// @dev Deploy inputs, read from the environment in `_readConfig`. Kept as a struct behind a
    ///      virtual reader so tests can inject values directly: `vm.setEnv` mutates process-global
    ///      state that forge does not roll back between test cases, which makes env-driven tests
    ///      race each other.
    struct DeployConfig {
        uint256 pk;
        address settlementToken;
        address feeRecipient;
        address protocolOwner;
        uint256 protocolFeeBps;
    }

    function _readConfig() internal view virtual returns (DeployConfig memory config) {
        config.pk = vm.envUint("PRIVATE_KEY");
        config.settlementToken = vm.envAddress("SETTLEMENT_TOKEN");
        config.feeRecipient = vm.envOr("FEE_RECIPIENT", address(0));
        config.protocolOwner = vm.envOr("PROTOCOL_OWNER", vm.addr(config.pk));
        config.protocolFeeBps = vm.envUint("PROTOCOL_FEE_BPS");
    }

    function run() external returns (PurchaseRefRegistry purchaseRefRegistry, NotaReceiptStore receiptStore) {
        DeployConfig memory config = _readConfig();
        uint256 pk = config.pk;
        address deployer = vm.addr(pk);
        address settlementToken = config.settlementToken;
        address feeRecipient = config.feeRecipient;
        address protocolOwner = config.protocolOwner;
        uint256 protocolFeeBpsRaw = config.protocolFeeBps;

        require(pk != 0, "PRIVATE_KEY is zero");
        require(settlementToken != address(0), "SETTLEMENT_TOKEN is zero");
        require(protocolOwner != address(0), "PROTOCOL_OWNER is zero");
        uint256 expectedProtocolFeeBps = _expectedProtocolFeeBps();
        require(
            protocolFeeBpsRaw == expectedProtocolFeeBps,
            "PROTOCOL_FEE_BPS does not match the expected fee for this chain  update the constant deliberately"
        );
        require(protocolFeeBpsRaw <= MAX_PROTOCOL_FEE_BPS, "PROTOCOL_FEE_BPS exceeds MAX_PROTOCOL_FEE_BPS");
        if (protocolFeeBpsRaw > 0) {
            require(feeRecipient != address(0), "FEE_RECIPIENT is zero");
        } else if (block.chainid == BASE_MAINNET_CHAIN_ID) {
            // Leave no fee destination on-chain, so "zero fee, cannot be turned on" is a property
            // an integrator can read off the deployed contract rather than a promise.
            require(feeRecipient == address(0), "Base mainnet: FEE_RECIPIENT must be zero at zero fee");
        }
        uint8 settlementTokenDecimals = _validateSettlementToken(settlementToken);

        // Safe because the value is capped to MAX_PROTOCOL_FEE_BPS above.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 protocolFeeBps = uint16(protocolFeeBpsRaw);

        console2.log("=== Nota ReceiptStore Deployment ===");
        console2.log("ChainId:", block.chainid);
        console2.log("SettlementTokenDecimals:", settlementTokenDecimals);
        console2.log("ExpectedProtocolFeeBps:", expectedProtocolFeeBps);

        vm.startBroadcast(pk);
        purchaseRefRegistry = new PurchaseRefRegistry(deployer);
        receiptStore = new NotaReceiptStore(
            settlementToken, address(purchaseRefRegistry), feeRecipient, protocolFeeBps, protocolOwner
        );
        purchaseRefRegistry.setConsumerAuthorization(address(receiptStore), true);
        if (protocolOwner != deployer) {
            purchaseRefRegistry.transferOwnership(protocolOwner);
        }
        vm.stopBroadcast();

        console2.log("ChainId:", block.chainid);
        console2.log("Deployer:", deployer);
        console2.log("ProtocolOwner:", protocolOwner);
        console2.log("SettlementToken:", settlementToken);
        console2.log("FeeRecipient:", feeRecipient);
        console2.log("ProtocolFeeBps:", protocolFeeBps);
        console2.log("PurchaseRefRegistry:", address(purchaseRefRegistry));
        console2.log("ReceiptStore:", address(receiptStore));
        console2.log("RegistryOwner:", purchaseRefRegistry.owner());
        console2.log("RegistryPendingOwner:", purchaseRefRegistry.pendingOwner());
        console2.log("ReceiptStoreAuthorized:", purchaseRefRegistry.authorizedConsumers(address(receiptStore)));
        console2.log("ReceiptStoreOwner:", receiptStore.owner());
    }

    /// @dev Expected protocol fee for the chain being deployed to. Base mainnet is pinned to
    ///      zero; every other chain uses the standard launch fee.
    function _expectedProtocolFeeBps() internal view returns (uint256) {
        if (block.chainid == BASE_MAINNET_CHAIN_ID) {
            return BASE_MAINNET_EXPECTED_PROTOCOL_FEE_BPS;
        }
        return EXPECTED_PROTOCOL_FEE_BPS;
    }

    /// @dev Validates that the settlement token is a 6-decimal ERC-20 such as USDC, and on
    ///      Base and Arbitrum One mainnet pins the address to Circle's canonical native USDC.
    ///      Other chains (testnets, future targets) require only the decimals match.
    function _validateSettlementToken(address settlementToken) internal view returns (uint8 decimals) {
        if (block.chainid == ARBITRUM_ONE_CHAIN_ID) {
            require(
                settlementToken == ARBITRUM_ONE_NATIVE_USDC,
                "Arbitrum One: SETTLEMENT_TOKEN must be canonical native USDC"
            );
        }
        if (block.chainid == BASE_MAINNET_CHAIN_ID) {
            require(settlementToken == BASE_MAINNET_NATIVE_USDC, "Base mainnet: SETTLEMENT_TOKEN must be native USDC");
        }
        decimals = IERC20Metadata(settlementToken).decimals();
        require(decimals == EXPECTED_SETTLEMENT_TOKEN_DECIMALS, "SETTLEMENT_TOKEN must use 6 decimals");
    }
}
