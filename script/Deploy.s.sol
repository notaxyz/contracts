// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PurchaseRefRegistry} from "../src/PurchaseRefRegistry.sol";
import {RevealReceiptStore} from "../src/RevealReceiptStore.sol";

contract Deploy is Script {
    uint256 internal constant MAX_PROTOCOL_FEE_BPS = 1_000;
    /// @dev Update this constant deliberately when the launch fee changes.
    uint256 internal constant EXPECTED_PROTOCOL_FEE_BPS = 50;
    /// @dev v1 purchase-amount constants assume a 6-decimal settlement token such as USDC.
    uint8 internal constant EXPECTED_SETTLEMENT_TOKEN_DECIMALS = 6;
    /// @dev Arbitrum One mainnet chain id.
    uint256 internal constant ARBITRUM_ONE_CHAIN_ID = 42161;
    /// @dev Circle's native USDC on Arbitrum One. USDC.e (bridged) is intentionally not accepted.
    address internal constant ARBITRUM_ONE_NATIVE_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address settlementToken = vm.envAddress("SETTLEMENT_TOKEN");
        address feeRecipient = vm.envOr("FEE_RECIPIENT", address(0));
        address protocolOwner = vm.envOr("PROTOCOL_OWNER", deployer);
        uint256 protocolFeeBpsRaw = vm.envUint("PROTOCOL_FEE_BPS");

        require(pk != 0, "PRIVATE_KEY is zero");
        require(settlementToken != address(0), "SETTLEMENT_TOKEN is zero");
        require(protocolOwner != address(0), "PROTOCOL_OWNER is zero");
        require(
            protocolFeeBpsRaw == EXPECTED_PROTOCOL_FEE_BPS,
            "PROTOCOL_FEE_BPS does not match EXPECTED_PROTOCOL_FEE_BPS  update the constant deliberately"
        );
        if (protocolFeeBpsRaw > 0) {
            require(feeRecipient != address(0), "FEE_RECIPIENT is zero");
        }
        uint8 settlementTokenDecimals = _validateSettlementToken(settlementToken);

        // Safe because the value is capped to MAX_PROTOCOL_FEE_BPS above.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 protocolFeeBps = uint16(protocolFeeBpsRaw);

        console2.log("=== zkReveal ReceiptStore Deployment ===");
        console2.log("ChainId:", block.chainid);
        console2.log("SettlementTokenDecimals:", settlementTokenDecimals);

        vm.startBroadcast(pk);
        PurchaseRefRegistry purchaseRefRegistry = new PurchaseRefRegistry(deployer);
        RevealReceiptStore receiptStore = new RevealReceiptStore(
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

    /// @dev Validates that the settlement token is a 6-decimal ERC-20 such as USDC, and on
    ///      Arbitrum One mainnet pins the address to Circle's canonical native USDC. Other chains
    ///      (testnets, future targets) require only the decimals match.
    function _validateSettlementToken(address settlementToken) internal view returns (uint8 decimals) {
        if (block.chainid == ARBITRUM_ONE_CHAIN_ID) {
            require(
                settlementToken == ARBITRUM_ONE_NATIVE_USDC,
                "Arbitrum One: SETTLEMENT_TOKEN must be canonical native USDC"
            );
        }
        decimals = IERC20Metadata(settlementToken).decimals();
        require(decimals == EXPECTED_SETTLEMENT_TOKEN_DECIMALS, "SETTLEMENT_TOKEN must use 6 decimals");
    }
}
