// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title PurchaseRefRegistry
/// @notice Canonical consume-once registry for zkReveal protocol purchase references.
/// @dev This contract is intentionally minimal, immutable, and non-upgradeable. Purchase refs
///      can only be consumed once and can never be deleted or unconsumed, including by the
///      registry owner. Only settlement contracts or modules explicitly authorized by the owner
///      may consume purchase refs. `consumer` means the settlement contract or module address
///      that consumed the ref. It is not necessarily the buyer or seller.
contract PurchaseRefRegistry is Ownable2Step {
    struct Consumption {
        address consumer;
        uint64 consumedAt;
    }

    mapping(address consumer => bool authorized) public authorizedConsumers;
    mapping(bytes32 purchaseRef => Consumption consumption) public consumptions;

    error InvalidOwner();
    error InvalidConsumer();
    error InvalidPurchaseRef();
    error UnauthorizedConsumer(address consumer);
    error PurchaseRefAlreadyConsumed(bytes32 purchaseRef, address consumer);

    event ConsumerAuthorizationChanged(address indexed consumer, bool authorized);
    event PurchaseRefConsumed(bytes32 indexed purchaseRef, address indexed consumer, uint64 consumedAt);

    constructor(address owner_) Ownable(_validateOwner(owner_)) {}

    /// @notice Authorize or revoke a settlement contract or module that may consume purchase refs.
    /// @dev The owner can manage which settlement modules are authorized, but can never delete or
    ///      unconsume purchase refs that were already consumed.
    function setConsumerAuthorization(address consumer, bool authorized) external onlyOwner {
        if (consumer == address(0)) revert InvalidConsumer();

        authorizedConsumers[consumer] = authorized;

        emit ConsumerAuthorizationChanged(consumer, authorized);
    }

    /// @notice Consume a `purchaseRef` once globally for the calling settlement contract or module.
    /// @dev Only settlement contracts or modules authorized by the registry owner may consume
    ///      purchase refs.
    function consume(bytes32 purchaseRef) external {
        if (!authorizedConsumers[msg.sender]) revert UnauthorizedConsumer(msg.sender);
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

    /// @notice Return the authorized settlement contract or module that consumed `purchaseRef`.
    /// @dev This consumer address is not the buyer or seller unless one of them is also the
    ///      settlement module that called `consume`.
    function consumedBy(bytes32 purchaseRef) external view returns (address) {
        return consumptions[purchaseRef].consumer;
    }

    function _validateOwner(address owner_) private pure returns (address) {
        if (owner_ == address(0)) revert InvalidOwner();
        return owner_;
    }
}
