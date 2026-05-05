// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {PurchaseRefRegistry} from "../src/PurchaseRefRegistry.sol";
import {RevealReceiptStore} from "../src/RevealReceiptStore.sol";

contract Deploy is Script {
    uint256 internal constant MAX_PROTOCOL_FEE_BPS = 1_000;

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
        require(protocolFeeBpsRaw <= MAX_PROTOCOL_FEE_BPS, "PROTOCOL_FEE_BPS too high");
        if (protocolFeeBpsRaw > 0) {
            require(feeRecipient != address(0), "FEE_RECIPIENT is zero");
        }

        // Safe because the value is capped to MAX_PROTOCOL_FEE_BPS above.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 protocolFeeBps = uint16(protocolFeeBpsRaw);

        console2.log("=== zkReveal ReceiptStore Deployment ===");
        console2.log("ChainId:", block.chainid);

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
}
