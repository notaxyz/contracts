// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title PurchaseRefRegistry
/// @notice Canonical consume-once registry for zkReveal protocol purchase references.
/// @dev This contract is intentionally minimal, immutable, and non-upgradeable. Purchase refs
///      can only be consumed once and can never be deleted or unconsumed. `consumer` means the
///      settlement contract or module address that consumed the ref. It is not necessarily the
///      buyer or seller.
contract PurchaseRefRegistry {
    struct Consumption {
        address consumer;
        uint64 consumedAt;
    }

    mapping(bytes32 purchaseRef => Consumption consumption) public consumptions;

    error InvalidPurchaseRef();
    error PurchaseRefAlreadyConsumed(bytes32 purchaseRef, address consumer);

    event PurchaseRefConsumed(bytes32 indexed purchaseRef, address indexed consumer, uint64 consumedAt);

    /// @notice Consume a `purchaseRef` once globally for the calling settlement contract or module.
    function consume(bytes32 purchaseRef) external {
        if (purchaseRef == bytes32(0)) revert InvalidPurchaseRef();

        Consumption storage consumption = consumptions[purchaseRef];
        if (consumption.consumer != address(0)) {
            revert PurchaseRefAlreadyConsumed(purchaseRef, consumption.consumer);
        }

        uint64 consumedAt = uint64(block.timestamp);
        consumption.consumer = msg.sender;
        consumption.consumedAt = consumedAt;

        emit PurchaseRefConsumed(purchaseRef, msg.sender, consumedAt);
    }

    /// @notice Return whether a `purchaseRef` has already been consumed.
    function isConsumed(bytes32 purchaseRef) external view returns (bool) {
        return consumptions[purchaseRef].consumer != address(0);
    }

    /// @notice Return the settlement contract or module address that consumed `purchaseRef`.
    /// @dev This consumer address is not the buyer or seller unless one of them is also the
    ///      settlement module that called `consume`.
    function consumedBy(bytes32 purchaseRef) external view returns (address) {
        return consumptions[purchaseRef].consumer;
    }
}
