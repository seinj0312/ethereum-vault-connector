// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../../utils/CreditVaultConnectorHarness.sol";

contract VaultStatusTest is Test {
    CreditVaultConnectorHarness internal cvc;

    function setUp() public {
        cvc = new CreditVaultConnectorHarness();
    }

    function test_RequireVaultStatusCheck(
        uint8 vaultsNumber,
        bool allStatusesValid
    ) external {
        vm.assume(vaultsNumber > 0 && vaultsNumber <= Set.MAX_ELEMENTS);

        for (uint i = 0; i < vaultsNumber; i++) {
            address vault = address(new Vault(cvc));

            // check all the options: vault state is ok, vault state is violated with
            // vault returning false and reverting
            Vault(vault).setVaultStatusState(
                allStatusesValid ? 0 : uint160(vault) % 3 == 0
                    ? 0
                    : uint160(vault) % 3 == 1
                    ? 1
                    : 2
            );

            vm.prank(vault);
            if (!(allStatusesValid || uint160(vault) % 3 == 0)) {
                vm.expectRevert(
                    abi.encodeWithSelector(
                        CreditVaultConnector.CVC_VaultStatusViolation.selector,
                        vault,
                        uint160(vault) % 3 == 1
                            ? bytes("vault status violation")
                            : abi.encodeWithSignature(
                                "Error(string)",
                                bytes("invalid vault")
                            )
                    )
                );
            }
            cvc.requireVaultStatusCheck();
            cvc.verifyVaultStatusChecks();
            cvc.clearExpectedChecks();
        }
    }

    function test_WhenDeferred_RequireVaultStatusCheck(
        uint8 vaultsNumber,
        bool allStatusesValid
    ) external {
        vm.assume(vaultsNumber > 0 && vaultsNumber <= Set.MAX_ELEMENTS);

        for (uint i = 0; i < vaultsNumber; i++) {
            address vault = address(new Vault(cvc));

            // check all the options: vault state is ok, vault state is violated with
            // vault returning false and reverting
            Vault(vault).setVaultStatusState(
                allStatusesValid ? 0 : uint160(vault) % 3 == 0
                    ? 0
                    : uint160(vault) % 3 == 1
                    ? 1
                    : 2
            );

            Vault(vault).setVaultStatusState(1);
            cvc.setBatchDepth(1);

            vm.prank(vault);

            // even though the vault status state was set to 1 which should revert,
            // it doesn't because in checks deferral we only add the vaults to the set
            // so that the checks can be performed later
            cvc.requireVaultStatusCheck();

            if (!(allStatusesValid || uint160(vault) % 3 == 0)) {
                // checks no longer deferred
                cvc.setBatchDepth(0);

                vm.prank(vault);
                vm.expectRevert(
                    abi.encodeWithSelector(
                        CreditVaultConnector.CVC_VaultStatusViolation.selector,
                        vault,
                        "vault status violation"
                    )
                );
                cvc.requireVaultStatusCheck();
            }
        }
    }

    function test_RequireVaultsStatusCheckNow(
        uint8 vaultsNumber,
        uint notRequestedVaultIndex,
        bool allStatusesValid
    ) external {
        vm.assume(vaultsNumber > 0 && vaultsNumber <= Set.MAX_ELEMENTS);
        vm.assume(notRequestedVaultIndex < vaultsNumber);

        address[] memory vaults = new address[](vaultsNumber);
        for (uint i = 0; i < vaultsNumber; i++) {
            vaults[i] = address(new Vault(cvc));
        }

        uint invalidVaultsCounter;
        address[] memory invalidVaults = new address[](vaultsNumber);

        for (uint i = 0; i < vaultsNumber; i++) {
            address vault = vaults[i];

            // check all the options: vault state is ok, vault state is violated with
            // vault returning false and reverting
            Vault(vault).setVaultStatusState(
                allStatusesValid ? 0 : uint160(vault) % 3 == 0
                    ? 0
                    : uint160(vault) % 3 == 1
                    ? 1
                    : 2
            );

            // fist, schedule the check to be performed later to prove that after being peformed on the fly
            // vault is no longer contained in the set to be performed later
            cvc.setBatchDepth(1);

            vm.prank(vault);
            cvc.requireVaultStatusCheck();

            Vault(vault).clearChecks();
            cvc.clearExpectedChecks();

            assertTrue(cvc.isVaultStatusCheckDeferred(vault));
            if (!(allStatusesValid || uint160(vault) % 3 == 0)) {
                // for later check
                invalidVaults[invalidVaultsCounter++] = vault;

                vm.expectRevert(
                    abi.encodeWithSelector(
                        CreditVaultConnector.CVC_VaultStatusViolation.selector,
                        vault,
                        uint160(vault) % 3 == 1
                            ? bytes("vault status violation")
                            : abi.encodeWithSignature(
                                "Error(string)",
                                bytes("invalid vault")
                            )
                    )
                );
            }
            cvc.requireVaultStatusCheckNow(vault);

            if (allStatusesValid || uint160(vault) % 3 == 0) {
                assertFalse(cvc.isVaultStatusCheckDeferred(vault));
                cvc.verifyVaultStatusChecks();
            }
        }

        // schedule the checks to be performed later to prove that after being peformed on the fly
        // vaults are no longer contained in the set to be performed later
        cvc.setBatchDepth(1);
        for (uint i = 0; i < vaultsNumber; i++) {
            address vault = vaults[i];
            vm.prank(vault);
            cvc.requireVaultStatusCheck();
            Vault(vault).clearChecks();
        }
        cvc.clearExpectedChecks();

        for (uint i = 0; i < vaultsNumber; ++i) {
            assertTrue(cvc.isVaultStatusCheckDeferred(vaults[i]));
        }
        if (invalidVaultsCounter > 0) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    CreditVaultConnector.CVC_VaultStatusViolation.selector,
                    invalidVaults[0],
                    uint160(invalidVaults[0]) % 3 == 1
                        ? bytes("vault status violation")
                        : abi.encodeWithSignature(
                            "Error(string)",
                            bytes("invalid vault")
                        )
                )
            );
        }
        cvc.requireVaultsStatusCheckNow(vaults);
        for (uint i = 0; i < vaultsNumber; ++i) {
            assertEq(
                cvc.isVaultStatusCheckDeferred(vaults[i]),
                invalidVaultsCounter > 0
            );
        }
        cvc.verifyVaultStatusChecks();

        // verify that the checks are not being performed if they hadn't been requested before
        cvc.reset();
        invalidVaults = new address[](vaultsNumber);
        delete invalidVaultsCounter;
        for (uint i = 0; i < vaultsNumber; i++) {
            address vault = vaults[i];

            cvc.setBatchDepth(1);

            if (i != notRequestedVaultIndex) {
                vm.prank(vault);
                cvc.requireVaultStatusCheck();
            }

            Vault(vault).clearChecks();
            cvc.clearExpectedChecks();

            assertEq(cvc.isVaultStatusCheckDeferred(vault), i != notRequestedVaultIndex);
            if (!(allStatusesValid || uint160(vault) % 3 == 0) && i != notRequestedVaultIndex) {
                // for later check
                invalidVaults[invalidVaultsCounter++] = vault;

                vm.expectRevert(
                    abi.encodeWithSelector(
                        CreditVaultConnector.CVC_VaultStatusViolation.selector,
                        vault,
                        uint160(vault) % 3 == 1
                            ? bytes("vault status violation")
                            : abi.encodeWithSignature(
                                "Error(string)",
                                bytes("invalid vault")
                            )
                    )
                );
            }
            cvc.requireVaultStatusCheckNow(vault);

            if (allStatusesValid || uint160(vault) % 3 == 0 && i != notRequestedVaultIndex) {
                assertFalse(cvc.isVaultStatusCheckDeferred(vault));
                cvc.verifyVaultStatusChecks();
            }

            if (i == notRequestedVaultIndex) {
                assertEq(Vault(vault).getVaultStatusChecked().length, 0);
            }
        }

        cvc.setBatchDepth(1);
        for (uint i = 0; i < vaultsNumber; i++) {
            address vault = vaults[i];

            if (i != notRequestedVaultIndex) {
                vm.prank(vault);
                cvc.requireVaultStatusCheck();
            }

            Vault(vault).clearChecks();
        }
        cvc.clearExpectedChecks();

        for (uint i = 0; i < vaultsNumber; ++i) {
            assertEq(cvc.isVaultStatusCheckDeferred(vaults[i]), i != notRequestedVaultIndex);
        }
        if (invalidVaultsCounter > 0) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    CreditVaultConnector.CVC_VaultStatusViolation.selector,
                    invalidVaults[0],
                    uint160(invalidVaults[0]) % 3 == 1
                        ? bytes("vault status violation")
                        : abi.encodeWithSignature(
                            "Error(string)",
                            bytes("invalid vault")
                        )
                )
            );
        }
        cvc.requireVaultsStatusCheckNow(vaults);
        for (uint i = 0; i < vaultsNumber; ++i) {
            assertEq(
                cvc.isVaultStatusCheckDeferred(vaults[i]),
                invalidVaultsCounter > 0 && i != notRequestedVaultIndex
            );
        }
        cvc.verifyVaultStatusChecks();
        assertEq(Vault(vaults[notRequestedVaultIndex]).getVaultStatusChecked().length, 0);
    }

    function test_ForgiveVaultStatusCheck(uint8 vaultsNumber) external {
        vm.assume(vaultsNumber > 0 && vaultsNumber <= Set.MAX_ELEMENTS);

        for (uint i = 0; i < vaultsNumber; i++) {
            address vault = address(new Vault(cvc));

            // vault status check will be scheduled for later due to deferred state
            cvc.setBatchDepth(1);

            vm.prank(vault);
            cvc.requireVaultStatusCheck();

            assertTrue(cvc.isVaultStatusCheckDeferred(vault));
            vm.prank(vault);
            cvc.forgiveVaultStatusCheck();
            assertFalse(cvc.isVaultStatusCheckDeferred(vault));
        }
    }
}
