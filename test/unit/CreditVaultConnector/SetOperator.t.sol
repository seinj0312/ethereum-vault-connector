// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../cvc/CreditVaultConnectorHarness.sol";

contract SetOperatorTest is Test {
    CreditVaultConnectorHarness internal cvc;

    event OperatorStatus(
        uint152 indexed addressPrefix,
        address indexed operator,
        uint accountOperatorAuthorized
    );
    event OwnerRegistered(uint152 indexed addressPrefix, address indexed owner);

    function setUp() public {
        cvc = new CreditVaultConnectorHarness();
    }

    function test_WhenOwnerCalling_SetOperator(
        address alice,
        address operator,
        uint accountOperatorAuthorized
    ) public {
        vm.assume(alice != address(0) && alice != address(cvc));
        vm.assume(operator != address(0) && operator != address(cvc));
        vm.assume(!cvc.haveCommonOwner(alice, operator));

        uint152 addressPrefix = cvc.getAddressPrefix(alice);
        vm.expectRevert(
            CreditVaultConnector.CVC_AccountOwnerNotRegistered.selector
        );
        cvc.getAccountOwner(alice);

        assertEq(cvc.getOperator(addressPrefix, operator), 0);

        vm.expectEmit(true, true, false, false, address(cvc));
        emit OwnerRegistered(addressPrefix, alice);
        if (accountOperatorAuthorized > 0) {
            vm.expectEmit(true, true, false, true, address(cvc));
            emit OperatorStatus(
                addressPrefix,
                operator,
                accountOperatorAuthorized
            );
        }
        vm.prank(alice);
        cvc.setOperator(addressPrefix, operator, accountOperatorAuthorized);

        assertEq(
            cvc.getOperator(addressPrefix, operator),
            accountOperatorAuthorized
        );

        // don't emit the event if the bit field doesn't change
        vm.recordLogs();
        vm.prank(alice);
        cvc.setOperator(addressPrefix, operator, accountOperatorAuthorized);

        {
            Vm.Log[] memory logs = vm.getRecordedLogs();
            assertEq(logs.length, 0);
            assertEq(
                cvc.getOperator(addressPrefix, operator),
                accountOperatorAuthorized
            );
            assertEq(cvc.getAccountOwner(alice), alice);
        }

        for (uint i = 0; i < 256; ++i) {
            address account = address(uint160(uint160(alice) ^ i));
            bool isAlreadyAuthorized = accountOperatorAuthorized & (1 << i) !=
                0;
            assertEq(
                cvc.isAccountOperatorAuthorized(account, operator),
                isAlreadyAuthorized
            );

            // authorize the operator
            if (!isAlreadyAuthorized) {
                vm.expectEmit(true, true, false, true, address(cvc));
                emit OperatorStatus(
                    addressPrefix,
                    operator,
                    accountOperatorAuthorized | (1 << i)
                );
            }
            vm.prank(alice);
            cvc.setAccountOperator(account, operator, true);
            assertEq(cvc.isAccountOperatorAuthorized(account, operator), true);

            // don't emit the event if the operator is already authorized
            vm.recordLogs();
            vm.prank(alice);
            cvc.setAccountOperator(account, operator, true);

            {
                Vm.Log[] memory logs = vm.getRecordedLogs();
                assertEq(logs.length, 0);
                assertEq(
                    cvc.isAccountOperatorAuthorized(account, operator),
                    true
                );
            }

            // deauthorize the operator
            vm.expectEmit(true, true, false, true, address(cvc));
            emit OperatorStatus(
                addressPrefix,
                operator,
                accountOperatorAuthorized & ~(1 << i)
            );
            vm.prank(alice);
            cvc.setAccountOperator(account, operator, false);
            assertEq(cvc.isAccountOperatorAuthorized(account, operator), false);

            // don't emit the event if the operator is already deauthorized
            vm.recordLogs();
            vm.prank(alice);
            cvc.setAccountOperator(account, operator, false);

            {
                Vm.Log[] memory logs = vm.getRecordedLogs();
                assertEq(logs.length, 0);
                assertEq(
                    cvc.isAccountOperatorAuthorized(account, operator),
                    false
                );
            }

            // restore to the original state
            vm.prank(alice);
            cvc.setOperator(addressPrefix, operator, accountOperatorAuthorized);
        }

        // reset the operator status
        if (accountOperatorAuthorized > 0) {
            vm.expectEmit(true, true, false, true, address(cvc));
            emit OperatorStatus(addressPrefix, operator, 0);
        }
        vm.prank(alice);
        cvc.setOperator(addressPrefix, operator, 0);

        assertEq(cvc.getOperator(addressPrefix, operator), 0);
    }

    function test_WhenOperatorCalling_SetOperator(
        address alice,
        address operator,
        uint seed
    ) public {
        vm.assume(alice != address(0) && alice != address(cvc));
        vm.assume(operator != address(0) && operator != address(cvc));
        vm.assume(!cvc.haveCommonOwner(alice, operator));

        for (uint i = 0; i < 256; ++i) {
            address account = address(uint160(uint160(alice) ^ i));
            uint152 addressPrefix = cvc.getAddressPrefix(account);
            assertEq(cvc.isAccountOperatorAuthorized(account, operator), false);

            if (i == 0) {
                vm.expectRevert(
                    CreditVaultConnector.CVC_AccountOwnerNotRegistered.selector
                );
                cvc.getAccountOwner(account);
            } else {
                assertEq(cvc.getAccountOwner(account), alice);
            }

            // authorize the operator
            if (i == 0) {
                vm.expectEmit(true, true, false, false, address(cvc));
                emit OwnerRegistered(cvc.getAddressPrefix(alice), alice);
            }
            vm.expectEmit(true, true, false, true, address(cvc));
            emit OperatorStatus(addressPrefix, operator, 1 << i);
            vm.recordLogs();
            vm.prank(alice);
            cvc.setAccountOperator(account, operator, true);
            Vm.Log[] memory logs = vm.getRecordedLogs();

            assertTrue(i == 0 ? logs.length == 2 : logs.length == 1); // OwnerRegistered event is emitted only once
            assertEq(cvc.isAccountOperatorAuthorized(account, operator), true);
            assertEq(cvc.getAccountOwner(account), alice);

            // the operator cannot call setOperator()
            vm.prank(operator);
            vm.expectRevert(CreditVaultConnector.CVC_NotAuthorized.selector);
            cvc.setOperator(addressPrefix, operator, seed);

            // but the operator can deauthorize itself calling setAccountOperator()
            vm.expectEmit(true, true, false, true, address(cvc));
            emit OperatorStatus(addressPrefix, operator, 0);
            vm.prank(operator);
            cvc.setAccountOperator(account, operator, false);

            assertEq(cvc.isAccountOperatorAuthorized(account, operator), false);
            assertEq(cvc.getAccountOwner(account), alice);
        }
    }

    function test_RevertIfSenderNotOwner_SetOperator(
        address alice,
        address operator,
        uint accountOperatorAuthorized
    ) public {
        uint152 addressPrefix = cvc.getAddressPrefix(alice);
        vm.assume(alice != address(0) && alice != address(cvc));
        vm.assume(operator != address(0));
        vm.assume(!cvc.haveCommonOwner(alice, operator));
        vm.assume(addressPrefix != type(uint152).max);

        // fails if address prefix does not belong to an owner
        vm.prank(alice);
        vm.expectRevert(CreditVaultConnector.CVC_NotAuthorized.selector);
        cvc.setOperator(addressPrefix + 1, operator, accountOperatorAuthorized);

        // succeeds if address prefix belongs to an owner
        vm.prank(alice);
        cvc.setOperator(addressPrefix, operator, accountOperatorAuthorized);

        // fails if owner not consistent
        vm.prank(address(uint160(uint160(alice) ^ 1)));
        vm.expectRevert(CreditVaultConnector.CVC_NotAuthorized.selector);
        cvc.setOperator(addressPrefix, operator, accountOperatorAuthorized);

        // reverts if sender is an operator
        vm.prank(operator);
        vm.expectRevert(CreditVaultConnector.CVC_NotAuthorized.selector);
        cvc.setOperator(addressPrefix, operator, accountOperatorAuthorized);
    }

    function test_RevertIfSenderNotOwnerAndNotOperator_SetAccountOperator(
        address alice,
        address operator
    ) public {
        vm.assume(
            alice != address(0) &&
                alice != address(0xfe) &&
                alice != address(cvc)
        );
        vm.assume(operator != address(0));
        vm.assume(!cvc.haveCommonOwner(alice, operator));

        address account = address(uint160(uint160(alice) ^ 256));

        vm.prank(alice);
        vm.expectRevert(CreditVaultConnector.CVC_NotAuthorized.selector);
        cvc.setAccountOperator(account, operator, true);

        // succeeds if sender is authorized
        account = address(uint160(uint160(alice) ^ 255));
        vm.prank(address(uint160(uint160(alice) ^ 254)));
        cvc.setAccountOperator(account, operator, true);

        // reverts if sender is not a registered owner nor operator
        vm.prank(alice);
        vm.expectRevert(CreditVaultConnector.CVC_NotAuthorized.selector);
        cvc.setAccountOperator(account, operator, true);

        // reverts if sender is not a registered owner nor operator
        vm.prank(address(uint160(uint160(operator) ^ 1)));
        vm.expectRevert(CreditVaultConnector.CVC_NotAuthorized.selector);
        cvc.setAccountOperator(account, operator, true);
    }

    function test_RevertWhenOperatorNotAuthorizedToPerformTheOperation_SetAccountOperator(
        address alice,
        address operator
    ) public {
        vm.assume(alice != address(0) && alice != address(cvc));
        vm.assume(
            operator != address(0) &&
                address(uint160(operator) ^ 1) != address(0) &&
                operator != address(cvc)
        );
        vm.assume(!cvc.haveCommonOwner(alice, operator));

        assertEq(cvc.isAccountOperatorAuthorized(alice, operator), false);

        vm.prank(alice);
        cvc.setAccountOperator(alice, operator, true);
        assertEq(cvc.isAccountOperatorAuthorized(alice, operator), true);

        // operator can re-authorize itself as it has no effect (but there will be no revert)
        vm.prank(operator);
        cvc.setAccountOperator(alice, operator, true);

        // operator cannot change authorization status for any other operator nor account
        vm.prank(operator);
        vm.expectRevert(CreditVaultConnector.CVC_NotAuthorized.selector);
        cvc.setAccountOperator(address(uint160(alice) ^ 1), operator, true);

        vm.prank(operator);
        vm.expectRevert(CreditVaultConnector.CVC_NotAuthorized.selector);
        cvc.setAccountOperator(alice, address(uint160(operator) ^ 1), true);

        vm.prank(alice);
        cvc.setAccountOperator(alice, address(uint160(operator) ^ 1), true);

        vm.prank(operator);
        vm.expectRevert(CreditVaultConnector.CVC_NotAuthorized.selector);
        cvc.setAccountOperator(alice, address(uint160(operator) ^ 1), false);

        // operator can deauthorize itself
        vm.prank(operator);
        cvc.setAccountOperator(alice, operator, false);

        assertEq(cvc.isAccountOperatorAuthorized(alice, operator), false);
    }

    function test_RevertIfOperatorIsInvalidAddress_SetOperator(
        address alice,
        uint8 subAccountId
    ) public {
        vm.assume(alice != address(cvc));
        uint152 addressPrefix = cvc.getAddressPrefix(alice);

        vm.prank(alice);
        vm.expectRevert(CreditVaultConnector.CVC_InvalidAddress.selector);
        cvc.setOperator(addressPrefix, address(0), 0);

        vm.prank(alice);
        vm.expectRevert(CreditVaultConnector.CVC_InvalidAddress.selector);
        cvc.setAccountOperator(alice, address(0), true);

        vm.prank(alice);
        vm.expectRevert(CreditVaultConnector.CVC_InvalidAddress.selector);
        cvc.setOperator(
            addressPrefix,
            address(uint160(alice) ^ subAccountId),
            0
        );

        vm.prank(alice);
        vm.expectRevert(CreditVaultConnector.CVC_InvalidAddress.selector);
        cvc.setAccountOperator(
            alice,
            address(uint160(alice) ^ subAccountId),
            true
        );
    }
}
