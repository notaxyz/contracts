// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Test} from "forge-std/Test.sol";

import {PurchaseRefRegistry} from "../src/PurchaseRefRegistry.sol";

contract PurchaseRefRegistryTest is Test {
    PurchaseRefRegistry registry;

    address consumerA = address(0xA11CE);
    address consumerB = address(0xB0B);

    bytes32 purchaseRef1 = keccak256("purchase-1");
    bytes32 purchaseRef2 = keccak256("purchase-2");

    function setUp() public {
        registry = new PurchaseRefRegistry(address(this));
    }

    function _assertConsumed(bytes32 ref, address expectedConsumer, uint64 expectedConsumedAt) internal view {
        (address consumer, uint64 consumedAt) = registry.consumptions(ref);
        assertTrue(registry.isConsumed(ref));
        assertEq(registry.consumedBy(ref), expectedConsumer);
        assertEq(consumer, expectedConsumer);
        assertEq(consumedAt, expectedConsumedAt);
    }

    function _assertNotConsumed(bytes32 ref) internal view {
        (address consumer, uint64 consumedAt) = registry.consumptions(ref);
        assertFalse(registry.isConsumed(ref));
        assertEq(registry.consumedBy(ref), address(0));
        assertEq(consumer, address(0));
        assertEq(consumedAt, 0);
    }

    function _authorize(address consumer) internal {
        registry.setConsumerAuthorization(consumer, true);
    }

    function test_Constructor_SetsOwner() public {
        PurchaseRefRegistry deployedRegistry = new PurchaseRefRegistry(consumerA);

        assertEq(deployedRegistry.owner(), consumerA);
    }

    function test_Constructor_ZeroOwnerReverts() public {
        vm.expectRevert(PurchaseRefRegistry.InvalidOwner.selector);
        new PurchaseRefRegistry(address(0));
    }

    function test_InitialState_ReturnsEmptyConsumption() public view {
        _assertNotConsumed(purchaseRef1);
    }

    function test_SetConsumerAuthorization_OwnerCanAuthorizeAndRevoke() public {
        registry.setConsumerAuthorization(consumerA, true);
        assertTrue(registry.authorizedConsumers(consumerA));

        registry.setConsumerAuthorization(consumerA, false);
        assertFalse(registry.authorizedConsumers(consumerA));
    }

    function test_SetConsumerAuthorization_RevokeBlocksFutureConsumesButDoesNotUnconsumeHistory() public {
        _authorize(consumerA);

        vm.prank(consumerA);
        registry.consume(purchaseRef1);

        registry.setConsumerAuthorization(consumerA, false);

        _assertConsumed(purchaseRef1, consumerA, uint64(block.timestamp));
        assertFalse(registry.authorizedConsumers(consumerA));

        vm.prank(consumerA);
        vm.expectRevert(abi.encodeWithSelector(PurchaseRefRegistry.UnauthorizedConsumer.selector, consumerA));
        registry.consume(purchaseRef2);
    }

    function test_SetConsumerAuthorization_NonOwnerReverts() public {
        vm.prank(consumerA);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, consumerA));
        registry.setConsumerAuthorization(consumerA, true);
    }

    function test_SetConsumerAuthorization_RejectsZeroConsumer() public {
        vm.expectRevert(PurchaseRefRegistry.InvalidConsumer.selector);
        registry.setConsumerAuthorization(address(0), true);
    }

    function test_SetConsumerAuthorization_EmitsEvent() public {
        vm.expectEmit(true, false, false, true, address(registry));
        emit PurchaseRefRegistry.ConsumerAuthorizationChanged(consumerA, true);

        registry.setConsumerAuthorization(consumerA, true);
    }

    function test_Consume_RevertsForUnauthorizedConsumer() public {
        vm.prank(consumerA);
        vm.expectRevert(abi.encodeWithSelector(PurchaseRefRegistry.UnauthorizedConsumer.selector, consumerA));
        registry.consume(purchaseRef1);
    }

    function test_Consume_StoresCallerAndTimestamp() public {
        uint64 expectedConsumedAt = 1_700_000_000;
        vm.warp(expectedConsumedAt);
        _authorize(consumerA);

        vm.prank(consumerA);
        registry.consume(purchaseRef1);

        _assertConsumed(purchaseRef1, consumerA, expectedConsumedAt);
    }

    function test_Consume_EmitsPurchaseRefConsumed() public {
        uint64 expectedConsumedAt = 1_700_000_000;
        vm.warp(expectedConsumedAt);
        _authorize(consumerA);

        vm.expectEmit(true, true, false, true, address(registry));
        emit PurchaseRefRegistry.PurchaseRefConsumed(purchaseRef1, consumerA, expectedConsumedAt);

        vm.prank(consumerA);
        registry.consume(purchaseRef1);
    }

    function test_Consume_RejectsZeroPurchaseRef() public {
        _authorize(address(this));
        vm.expectRevert(PurchaseRefRegistry.InvalidPurchaseRef.selector);
        registry.consume(bytes32(0));
    }

    function test_Consume_ZeroPurchaseRefUnauthorizedCallerRevertsUnauthorizedFirst() public {
        vm.prank(consumerA);
        vm.expectRevert(abi.encodeWithSelector(PurchaseRefRegistry.UnauthorizedConsumer.selector, consumerA));
        registry.consume(bytes32(0));
    }

    function test_Consume_RevertsWhenAlreadyConsumedBySameCaller() public {
        _authorize(consumerA);
        vm.prank(consumerA);
        registry.consume(purchaseRef1);

        vm.prank(consumerA);
        vm.expectRevert(
            abi.encodeWithSelector(PurchaseRefRegistry.PurchaseRefAlreadyConsumed.selector, purchaseRef1, consumerA)
        );
        registry.consume(purchaseRef1);
    }

    function test_Consume_RevertsWhenAlreadyConsumedByDifferentCaller() public {
        _authorize(consumerA);
        _authorize(consumerB);
        vm.prank(consumerA);
        registry.consume(purchaseRef1);

        vm.prank(consumerB);
        vm.expectRevert(
            abi.encodeWithSelector(PurchaseRefRegistry.PurchaseRefAlreadyConsumed.selector, purchaseRef1, consumerA)
        );
        registry.consume(purchaseRef1);
    }

    function test_Consume_AllowsDifferentRefsForSameConsumer() public {
        uint64 firstConsumedAt = 1_700_000_000;
        uint64 secondConsumedAt = firstConsumedAt + 1;
        _authorize(consumerA);

        vm.warp(firstConsumedAt);
        vm.prank(consumerA);
        registry.consume(purchaseRef1);

        vm.warp(secondConsumedAt);
        vm.prank(consumerA);
        registry.consume(purchaseRef2);

        _assertConsumed(purchaseRef1, consumerA, firstConsumedAt);
        _assertConsumed(purchaseRef2, consumerA, secondConsumedAt);
    }

    function test_Consume_AllowsDifferentConsumersForDifferentRefs() public {
        uint64 firstConsumedAt = 1_700_000_000;
        uint64 secondConsumedAt = firstConsumedAt + 1;
        _authorize(consumerA);
        _authorize(consumerB);

        vm.warp(firstConsumedAt);
        vm.prank(consumerA);
        registry.consume(purchaseRef1);

        vm.warp(secondConsumedAt);
        vm.prank(consumerB);
        registry.consume(purchaseRef2);

        _assertConsumed(purchaseRef1, consumerA, firstConsumedAt);
        _assertConsumed(purchaseRef2, consumerB, secondConsumedAt);
    }

    function test_Consume_DoesNotModifyOtherRefs() public {
        _authorize(consumerA);
        vm.prank(consumerA);
        registry.consume(purchaseRef1);

        _assertConsumed(purchaseRef1, consumerA, uint64(block.timestamp));
        _assertNotConsumed(purchaseRef2);
    }

    function test_ConsumedBy_ReturnsZeroForUnusedPurchaseRef() public view {
        assertEq(registry.consumedBy(purchaseRef1), address(0));
    }

    function test_IsConsumed_ReturnsFalseForZeroPurchaseRef() public view {
        assertFalse(registry.isConsumed(bytes32(0)));
        assertEq(registry.consumedBy(bytes32(0)), address(0));
    }
}
