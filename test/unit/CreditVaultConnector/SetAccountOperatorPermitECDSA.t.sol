// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../utils/mocks/Operator.sol";
import "../../../src/test/CreditVaultConnectorHarness.sol";
import "openzeppelin/utils/cryptography/ECDSA.sol";
import {ShortStrings, ShortString} from "openzeppelin/utils/ShortStrings.sol";

abstract contract EIP712 {
    using ShortStrings for *;

    bytes32 internal constant _TYPE_HASH =
        keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );

    bytes32 internal immutable _hashedName;
    bytes32 internal immutable _hashedVersion;

    ShortString private immutable _name;
    ShortString private immutable _version;
    string private _nameFallback;
    string private _versionFallback;

    /**
     * @dev Initializes the domain separator.
     *
     * The meaning of `name` and `version` is specified in
     * https://eips.ethereum.org/EIPS/eip-712#definition-of-domainseparator[EIP 712]:
     *
     * - `name`: the user readable name of the signing domain, i.e. the name of the DApp or the protocol.
     * - `version`: the current major version of the signing domain.
     *
     * NOTE: These parameters cannot be changed except through a xref:learn::upgrading-smart-contracts.adoc[smart
     * contract upgrade].
     */
    constructor(string memory name, string memory version) {
        _name = name.toShortStringWithFallback(_nameFallback);
        _version = version.toShortStringWithFallback(_versionFallback);
        _hashedName = keccak256(bytes(name));
        _hashedVersion = keccak256(bytes(version));
    }

    /**
     * @dev Returns the domain separator for the current chain.
     */
    function _domainSeparatorV4() internal view returns (bytes32) {
        return _buildDomainSeparator();
    }

    function _buildDomainSeparator() internal view virtual returns (bytes32) {
        return bytes32(0);
    }

    /**
     * @dev Given an already https://eips.ethereum.org/EIPS/eip-712#definition-of-hashstruct[hashed struct], this
     * function returns the hash of the fully encoded EIP712 message for this domain.
     *
     * This hash can be used together with {ECDSA-recover} to obtain the signer of a message. For example:
     *
     * ```solidity
     * bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(
     *     keccak256("Mail(address to,string contents)"),
     *     mailTo,
     *     keccak256(bytes(mailContents))
     * )));
     * address signer = ECDSA.recover(digest, signature);
     * ```
     */
    function _hashTypedDataV4(
        bytes32 structHash
    ) internal view virtual returns (bytes32) {
        return ECDSA.toTypedDataHash(_domainSeparatorV4(), structHash);
    }
}

contract Signer is EIP712, Test {
    CreditVaultConnector private immutable cvc;
    uint256 private privateKey;

    constructor(CreditVaultConnector _cvc) EIP712(_cvc.name(), _cvc.version()) {
        cvc = _cvc;
    }

    function setPrivateKey(uint256 _privateKey) external {
        privateKey = _privateKey;
    }

    function _buildDomainSeparator() internal view override returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    _TYPE_HASH,
                    _hashedName,
                    _hashedVersion,
                    block.chainid,
                    address(cvc)
                )
            );
    }

    function signPermit(
        address account,
        address operator,
        bytes calldata operatorData,
        uint40 authExpiryTimestamp,
        uint40 signatureTimestamp,
        uint40 signatureDeadlineTimestamp
    ) external view returns (bytes memory signature) {
        bytes32 structHash = keccak256(
            abi.encode(
                cvc.OPERATOR_PERMIT_TYPEHASH(),
                account,
                operator,
                keccak256(operatorData),
                authExpiryTimestamp,
                signatureTimestamp,
                signatureDeadlineTimestamp
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            privateKey,
            _hashTypedDataV4(structHash)
        );
        signature = abi.encodePacked(r, s, v);
    }
}

contract installAccountOperatorPermitECDSATest is Test {
    CreditVaultConnectorHarness internal cvc;
    Signer internal signer;

    event AccountOperatorAuthorized(
        address indexed account,
        address indexed operator,
        uint authExpiryTimestamp
    );
    event AccountsOwnerRegistered(
        uint152 indexed prefix,
        address indexed owner
    );

    function setUp() public {
        cvc = new CreditVaultConnectorHarness();
        signer = new Signer(cvc);
    }

    function test_installAccountOperatorPermitECDSA(
        uint privateKey,
        bytes memory operatorData,
        uint16 value,
        uint40 authExpiry,
        uint40 seed
    ) public {
        vm.assume(
            privateKey > 0 &&
                privateKey <
                115792089237316195423570985008687907852837564279074904382605163141518161494337
        );
        address alice = vm.addr(privateKey);
        address payable operator = payable(new Operator());

        vm.assume(!cvc.haveCommonOwner(alice, operator));
        vm.assume(
            bytes4(operatorData) != 0xc41e79ed &&
                bytes4(operatorData) != 0xb79bb2d7 &&
                bytes4(operatorData) != 0x1234458c
        );
        vm.assume(authExpiry >= seed && authExpiry < type(uint40).max - 1);
        vm.assume(seed > 0 && seed < type(uint40).max - 10);
        vm.assume(value < type(uint16).max - 10);

        vm.deal(msg.sender, type(uint128).max);

        signer.setPrivateKey(privateKey);

        for (uint i = 0; i < 256; ++i) {
            vm.warp(seed);

            address account = address(uint160(uint160(alice) ^ i));

            {
                uint40 expiryTimestamp = cvc
                    .getAccountOperatorAuthExpiryTimestamp(account, operator);
                (, uint40 lastSignatureTimestamp) = cvc
                    .getLastSignatureTimestamps(account, operator);
                assertEq(expiryTimestamp, 0);
                assertEq(lastSignatureTimestamp, 0);
            }

            if (i == 0) {
                vm.expectRevert(
                    CreditVaultConnector.CVC_AccountOwnerNotRegistered.selector
                );
                cvc.getAccountOwner(account);
            } else {
                assertEq(cvc.getAccountOwner(account), alice);
            }

            Operator(operator).clearFallbackCalled();
            Operator(operator).setExpectedHash(operatorData);
            Operator(operator).setExpectedValue(value);

            // sign permit
            bytes memory signature = signer.signPermit(
                account,
                operator,
                operatorData,
                authExpiry,
                uint40(block.timestamp),
                uint40(block.timestamp)
            );

            // authorize the operator
            if (i == 0) {
                vm.expectEmit(true, true, false, false, address(cvc));
                emit AccountsOwnerRegistered(cvc.getPrefix(alice), alice);
            }
            vm.expectEmit(true, true, false, true, address(cvc));
            emit AccountOperatorAuthorized(account, operator, authExpiry);
            vm.recordLogs();
            cvc.installAccountOperatorPermitECDSA{value: value}(
                account,
                operator,
                operatorData,
                authExpiry,
                uint40(block.timestamp),
                uint40(block.timestamp),
                signature
            );
            Vm.Log[] memory logs = vm.getRecordedLogs();

            {
                assertTrue(i == 0 ? logs.length == 2 : logs.length == 1); // AccountsOwnerRegistered event is emitted only once
                uint40 expiryTimestamp = cvc
                    .getAccountOperatorAuthExpiryTimestamp(account, operator);
                (, uint40 lastSignatureTimestamp) = cvc
                    .getLastSignatureTimestamps(account, operator);
                assertEq(expiryTimestamp, authExpiry);
                assertEq(lastSignatureTimestamp, block.timestamp);
                assertEq(
                    Operator(operator).fallbackCalled(),
                    operatorData.length > 0 ? true : false
                );
                assertEq(cvc.getAccountOwner(account), alice);
            }

            // it's not possible to carry out a reply attack
            vm.expectRevert(CreditVaultConnector.CVC_InvalidTimestamp.selector);
            cvc.installAccountOperatorPermitECDSA{value: value}(
                account,
                operator,
                operatorData,
                authExpiry,
                uint40(block.timestamp),
                uint40(block.timestamp),
                signature
            );

            // don't emit the event if the operator is already enabled with the same expiry timestamp
            Operator(operator).clearFallbackCalled();
            Operator(operator).setExpectedHash(
                bytes(abi.encode(operatorData, "1"))
            );
            Operator(operator).setExpectedValue(value + 1);

            vm.warp(block.timestamp + 1);
            signature = signer.signPermit(
                account,
                operator,
                bytes(abi.encode(operatorData, "1")),
                authExpiry,
                uint40(block.timestamp),
                uint40(block.timestamp)
            );

            vm.recordLogs();
            cvc.installAccountOperatorPermitECDSA{value: value + 1}(
                account,
                operator,
                bytes(abi.encode(operatorData, "1")),
                authExpiry,
                uint40(block.timestamp),
                uint40(block.timestamp),
                signature
            );
            logs = vm.getRecordedLogs();

            {
                assertEq(logs.length, 0);
                uint40 expiryTimestamp = cvc
                    .getAccountOperatorAuthExpiryTimestamp(account, operator);
                (, uint40 lastSignatureTimestamp) = cvc
                    .getLastSignatureTimestamps(account, operator);
                assertEq(expiryTimestamp, authExpiry);
                assertEq(lastSignatureTimestamp, block.timestamp);
                assertEq(Operator(operator).fallbackCalled(), true);
                assertEq(cvc.getAccountOwner(account), alice);
            }

            // change the authorization expiry timestamp
            Operator(operator).clearFallbackCalled();
            Operator(operator).setExpectedHash(
                bytes(abi.encode(operatorData, "2"))
            );
            Operator(operator).setExpectedValue(value + 2);

            vm.warp(block.timestamp + 1);
            signature = signer.signPermit(
                account,
                operator,
                bytes(abi.encode(operatorData, "2")),
                authExpiry + 1,
                uint40(block.timestamp),
                uint40(block.timestamp)
            );

            vm.expectEmit(true, true, false, true, address(cvc));
            emit AccountOperatorAuthorized(account, operator, authExpiry + 1);
            vm.recordLogs();
            cvc.installAccountOperatorPermitECDSA{value: value + 2}(
                account,
                operator,
                bytes(abi.encode(operatorData, "2")),
                authExpiry + 1,
                uint40(block.timestamp),
                uint40(block.timestamp),
                signature
            );
            logs = vm.getRecordedLogs();

            {
                assertEq(logs.length, 1);
                uint40 expiryTimestamp = cvc
                    .getAccountOperatorAuthExpiryTimestamp(account, operator);
                (, uint40 lastSignatureTimestamp) = cvc
                    .getLastSignatureTimestamps(account, operator);
                assertEq(expiryTimestamp, authExpiry + 1);
                assertEq(lastSignatureTimestamp, block.timestamp);
                assertEq(Operator(operator).fallbackCalled(), true);
                assertEq(cvc.getAccountOwner(account), alice);
            }

            // deauthorize the operator
            Operator(operator).clearFallbackCalled();
            Operator(operator).setExpectedHash(
                bytes(abi.encode(operatorData, "3"))
            );
            Operator(operator).setExpectedValue(value + 3);

            vm.warp(block.timestamp + 1);
            signature = signer.signPermit(
                account,
                operator,
                bytes(abi.encode(operatorData, "3")),
                1,
                uint40(block.timestamp),
                uint40(block.timestamp)
            );

            vm.expectEmit(true, true, false, true, address(cvc));
            emit AccountOperatorAuthorized(account, operator, 1);
            vm.recordLogs();
            cvc.installAccountOperatorPermitECDSA{value: value + 3}(
                account,
                operator,
                bytes(abi.encode(operatorData, "3")),
                1,
                uint40(block.timestamp),
                uint40(block.timestamp),
                signature
            );
            logs = vm.getRecordedLogs();

            {
                assertEq(logs.length, 1);
                uint40 expiryTimestamp = cvc
                    .getAccountOperatorAuthExpiryTimestamp(account, operator);
                (, uint40 lastSignatureTimestamp) = cvc
                    .getLastSignatureTimestamps(account, operator);
                assertEq(expiryTimestamp, 1);
                assertEq(lastSignatureTimestamp, block.timestamp);
                assertEq(Operator(operator).fallbackCalled(), true);
                assertEq(cvc.getAccountOwner(account), alice);
            }

            // don't emit the event if the operator is already deauthorized with the same timestamp
            Operator(operator).clearFallbackCalled();
            Operator(operator).setExpectedHash(
                bytes(abi.encode(operatorData, "4"))
            );
            Operator(operator).setExpectedValue(value + 4);

            vm.warp(block.timestamp + 1);
            signature = signer.signPermit(
                account,
                operator,
                bytes(abi.encode(operatorData, "4")),
                1,
                uint40(block.timestamp),
                uint40(block.timestamp)
            );

            vm.recordLogs();
            cvc.installAccountOperatorPermitECDSA{value: value + 4}(
                account,
                operator,
                bytes(abi.encode(operatorData, "4")),
                1,
                uint40(block.timestamp),
                uint40(block.timestamp),
                signature
            );
            logs = vm.getRecordedLogs();

            {
                assertEq(logs.length, 0);
                uint40 expiryTimestamp = cvc
                    .getAccountOperatorAuthExpiryTimestamp(account, operator);
                (, uint40 lastSignatureTimestamp) = cvc
                    .getLastSignatureTimestamps(account, operator);
                assertEq(expiryTimestamp, 1);
                assertEq(lastSignatureTimestamp, block.timestamp);
                assertEq(Operator(operator).fallbackCalled(), true);
                assertEq(cvc.getAccountOwner(account), alice);
            }

            // approve the operator only for the timebeing of the operator callback if the special value is used
            Operator(operator).clearFallbackCalled();
            Operator(operator).setExpectedHash(
                bytes(abi.encode(operatorData, "5"))
            );
            Operator(operator).setExpectedValue(value + 5);

            vm.warp(block.timestamp + 1);
            signature = signer.signPermit(
                account,
                operator,
                bytes(abi.encode(operatorData, "5")),
                0,
                uint40(block.timestamp),
                uint40(block.timestamp)
            );

            vm.expectEmit(true, true, false, true, address(cvc));
            emit AccountOperatorAuthorized(account, operator, 0);
            vm.recordLogs();
            cvc.installAccountOperatorPermitECDSA{value: value + 5}(
                account,
                operator,
                bytes(abi.encode(operatorData, "5")),
                0,
                uint40(block.timestamp),
                uint40(block.timestamp),
                signature
            );

            {
                logs = vm.getRecordedLogs();
                assertTrue(logs.length == 1);
                uint40 expiryTimestamp = cvc
                    .getAccountOperatorAuthExpiryTimestamp(account, operator);
                (, uint40 lastSignatureTimestamp) = cvc
                    .getLastSignatureTimestamps(account, operator);
                assertEq(expiryTimestamp, 0);
                assertEq(lastSignatureTimestamp, block.timestamp);
                assertEq(Operator(operator).fallbackCalled(), true);
                assertEq(cvc.getAccountOwner(account), alice);
            }
        }
    }

    function test_BatchCallback_installAccountOperatorPermitECDSA(
        uint privateKey,
        address collateral,
        uint40 seed
    ) public {
        vm.assume(
            privateKey > 0 &&
                privateKey <
                115792089237316195423570985008687907852837564279074904382605163141518161494337
        );

        address alice = vm.addr(privateKey);
        address operator = address(new OperatorBatchCallback());
        vm.assume(!cvc.haveCommonOwner(alice, operator));
        vm.assume(seed > 0 && seed < type(uint40).max - 10);

        vm.warp(seed);

        ICVC.BatchItem[] memory items = new ICVC.BatchItem[](1);
        items[0].onBehalfOfAccount = alice;
        items[0].targetContract = address(cvc);
        items[0].value = 0;
        items[0].data = abi.encodeWithSelector(
            cvc.enableCollateral.selector,
            alice,
            collateral
        );
        bytes memory operatorData = abi.encodeWithSelector(
            OperatorBatchCallback.callBatch.selector,
            address(cvc),
            items
        );

        signer.setPrivateKey(privateKey);
        bytes memory signature = signer.signPermit(
            alice,
            operator,
            operatorData,
            0,
            uint40(block.timestamp),
            uint40(block.timestamp)
        );

        cvc.installAccountOperatorPermitECDSA(
            alice,
            operator,
            operatorData,
            0,
            uint40(block.timestamp),
            uint40(block.timestamp),
            signature
        );

        assertEq(cvc.isCollateralEnabled(alice, collateral), true);
        assertEq(cvc.getAccountOperatorAuthExpiryTimestamp(alice, operator), 0);
    }

    function test_RevertIfOperatorCallReentrancy_installAccountOperatorPermitECDSA(
        uint privateKey,
        bytes calldata operatorData,
        uint40 seed
    ) public {
        vm.assume(
            privateKey > 0 &&
                privateKey <
                115792089237316195423570985008687907852837564279074904382605163141518161494337
        );
        address alice = vm.addr(privateKey);
        address payable operator = payable(new OperatorMaliciousECDSA());
        vm.assume(!cvc.haveCommonOwner(alice, operator));
        vm.assume(
            bytes4(operatorData) != 0xc41e79ed &&
                bytes4(operatorData) != 0xb79bb2d7 &&
                bytes4(operatorData) != 0x1234458c
        );
        vm.assume(seed > 0 && seed < type(uint40).max - 10);
        vm.assume(operatorData.length > 0);
        vm.warp(seed);

        signer.setPrivateKey(privateKey);

        bytes memory signature = signer.signPermit(
            alice,
            operator,
            operatorData,
            0,
            uint40(block.timestamp),
            uint40(block.timestamp)
        );

        // CVC_OperatorCallFailure is expected due to OperatorMaliciousECDSA reverting.
        // look at OperatorMaliciousECDSA implementation for details.
        vm.expectRevert(CreditVaultConnector.CVC_OperatorCallFailure.selector);

        cvc.installAccountOperatorPermitECDSA(
            alice,
            operator,
            operatorData,
            0,
            uint40(block.timestamp),
            uint40(block.timestamp),
            signature
        );

        // succeeds if operator is not called due to empty operatorData
        signature = signer.signPermit(
            alice,
            operator,
            bytes(""),
            0,
            uint40(block.timestamp),
            uint40(block.timestamp)
        );
        cvc.installAccountOperatorPermitECDSA(
            alice,
            operator,
            bytes(""),
            0,
            uint40(block.timestamp),
            uint40(block.timestamp),
            signature
        );
    }

    function test_RevertIfSignerNotAuthorized_installAccountOperatorPermitECDSA(
        uint privateKey,
        address operator
    ) public {
        vm.assume(
            privateKey > 0 &&
                privateKey <
                115792089237316195423570985008687907852837564279074904382605163141518161494337
        );
        address alice = vm.addr(privateKey);
        vm.assume(!cvc.haveCommonOwner(alice, operator));

        signer.setPrivateKey(privateKey);

        address account = address(uint160(uint160(alice) ^ 256));
        bytes memory signature = signer.signPermit(
            account,
            operator,
            bytes(""),
            0,
            uint40(block.timestamp),
            uint40(block.timestamp)
        );

        vm.expectRevert(CreditVaultConnector.CVC_NotAuthorized.selector);
        cvc.installAccountOperatorPermitECDSA(
            account,
            operator,
            bytes(""),
            0,
            uint40(block.timestamp),
            uint40(block.timestamp),
            signature
        );

        // succeeds if signer is authorized
        account = address(uint160(uint160(alice) ^ 255));
        signature = signer.signPermit(
            account,
            operator,
            bytes(""),
            0,
            uint40(block.timestamp),
            uint40(block.timestamp)
        );

        cvc.installAccountOperatorPermitECDSA(
            account,
            operator,
            bytes(""),
            0,
            uint40(block.timestamp),
            uint40(block.timestamp),
            signature
        );

        // reverts if signer is not a registered owner
        vm.warp(block.timestamp + 1);
        signer.setPrivateKey(uint(keccak256(abi.encode(privateKey)))); // not a registered owner
        signature = signer.signPermit(
            account,
            operator,
            bytes(""),
            0,
            uint40(block.timestamp),
            uint40(block.timestamp)
        );

        vm.expectRevert(CreditVaultConnector.CVC_NotAuthorized.selector);
        cvc.installAccountOperatorPermitECDSA(
            account,
            operator,
            bytes(""),
            0,
            uint40(block.timestamp),
            uint40(block.timestamp),
            signature
        );
    }

    function test_RevertIfOperatorIsOwnersAccount_installAccountOperatorPermitECDSA(
        uint privateKey,
        uint8 subAccountId
    ) public {
        vm.assume(
            privateKey > 0 &&
                privateKey <
                115792089237316195423570985008687907852837564279074904382605163141518161494337
        );
        address alice = vm.addr(privateKey);
        address operator = address(uint160(uint160(alice) ^ subAccountId));

        signer.setPrivateKey(privateKey);

        bytes memory signature = signer.signPermit(
            alice,
            operator,
            bytes(""),
            0,
            uint40(block.timestamp),
            uint40(block.timestamp)
        );

        vm.expectRevert(CreditVaultConnector.CVC_InvalidAddress.selector);
        cvc.installAccountOperatorPermitECDSA(
            alice,
            operator,
            bytes(""),
            0,
            uint40(block.timestamp),
            uint40(block.timestamp),
            signature
        );
    }

    function test_RevertIfSignatureTimestampInThePast_installAccountOperatorPermitECDSA(
        uint privateKey,
        address operator,
        uint40 seed
    ) public {
        vm.assume(
            privateKey > 0 &&
                privateKey <
                115792089237316195423570985008687907852837564279074904382605163141518161494337
        );
        address alice = vm.addr(privateKey);
        vm.assume(!cvc.haveCommonOwner(alice, operator));
        vm.assume(seed > 0 && seed < type(uint40).max);

        signer.setPrivateKey(privateKey);

        vm.warp(seed);

        // succeeds as the first signature is not in the past
        uint40 lastSignatureTimestamp = uint40(block.timestamp);
        bytes memory signature = signer.signPermit(
            alice,
            operator,
            bytes(""),
            0,
            lastSignatureTimestamp,
            uint40(block.timestamp)
        );
        cvc.installAccountOperatorPermitECDSA(
            alice,
            operator,
            bytes(""),
            0,
            lastSignatureTimestamp,
            uint40(block.timestamp),
            signature
        );

        // time elapses
        vm.warp(block.timestamp + 1);

        // this signature is in the past hence it reverts
        signature = signer.signPermit(
            alice,
            operator,
            bytes(""),
            0,
            lastSignatureTimestamp,
            uint40(block.timestamp)
        );
        vm.expectRevert(CreditVaultConnector.CVC_InvalidTimestamp.selector);
        cvc.installAccountOperatorPermitECDSA(
            alice,
            operator,
            bytes(""),
            0,
            lastSignatureTimestamp,
            uint40(block.timestamp),
            signature
        );

        // this signature is even more in the past hence it reverts
        signature = signer.signPermit(
            alice,
            operator,
            bytes(""),
            0,
            0,
            uint40(block.timestamp)
        );
        vm.expectRevert(CreditVaultConnector.CVC_InvalidTimestamp.selector);
        cvc.installAccountOperatorPermitECDSA(
            alice,
            operator,
            bytes(""),
            0,
            0,
            uint40(block.timestamp),
            signature
        );

        // succeeds if signature timestamp is not in the past
        signature = signer.signPermit(
            alice,
            operator,
            bytes(""),
            0,
            uint40(block.timestamp),
            uint40(block.timestamp)
        );
        cvc.installAccountOperatorPermitECDSA(
            alice,
            operator,
            bytes(""),
            0,
            uint40(block.timestamp),
            uint40(block.timestamp),
            signature
        );
    }

    function test_RevertIfSignatureTimestampInTheFuture_installAccountOperatorPermitECDSA(
        uint privateKey,
        address operator,
        uint40 seed
    ) public {
        vm.assume(
            privateKey > 0 &&
                privateKey <
                115792089237316195423570985008687907852837564279074904382605163141518161494337
        );
        address alice = vm.addr(privateKey);
        vm.assume(!cvc.haveCommonOwner(alice, operator));
        vm.assume(seed > 0 && seed < type(uint40).max);

        vm.warp(seed);

        signer.setPrivateKey(privateKey);

        bytes memory signature = signer.signPermit(
            alice,
            operator,
            bytes(""),
            0,
            uint40(block.timestamp + 1),
            uint40(block.timestamp)
        );
        vm.expectRevert(CreditVaultConnector.CVC_InvalidTimestamp.selector);
        cvc.installAccountOperatorPermitECDSA(
            alice,
            operator,
            bytes(""),
            0,
            uint40(block.timestamp + 1),
            uint40(block.timestamp),
            signature
        );

        // succeeds if signature timestamp is not in the future
        signature = signer.signPermit(
            alice,
            operator,
            bytes(""),
            0,
            uint40(block.timestamp),
            uint40(block.timestamp)
        );
        cvc.installAccountOperatorPermitECDSA(
            alice,
            operator,
            bytes(""),
            0,
            uint40(block.timestamp),
            uint40(block.timestamp),
            signature
        );
    }

    function test_RevertIfSignatureDeadlineMissed_installAccountOperatorPermitECDSA(
        uint privateKey,
        address operator,
        uint40 seed
    ) public {
        vm.assume(
            privateKey > 0 &&
                privateKey <
                115792089237316195423570985008687907852837564279074904382605163141518161494337
        );
        address alice = vm.addr(privateKey);
        vm.assume(!cvc.haveCommonOwner(alice, operator));
        vm.assume(seed > 0 && seed < type(uint40).max);

        vm.warp(seed);

        signer.setPrivateKey(privateKey);

        bytes memory signature = signer.signPermit(
            alice,
            operator,
            bytes(""),
            0,
            uint40(block.timestamp),
            uint40(block.timestamp - 1)
        );
        vm.expectRevert(CreditVaultConnector.CVC_InvalidTimestamp.selector);
        cvc.installAccountOperatorPermitECDSA(
            alice,
            operator,
            bytes(""),
            0,
            uint40(block.timestamp),
            uint40(block.timestamp - 1),
            signature
        );

        // succeeds if deadline is not missed
        signature = signer.signPermit(
            alice,
            operator,
            bytes(""),
            0,
            uint40(block.timestamp),
            uint40(block.timestamp)
        );
        cvc.installAccountOperatorPermitECDSA(
            alice,
            operator,
            bytes(""),
            0,
            uint40(block.timestamp),
            uint40(block.timestamp),
            signature
        );
    }

    function test_RevertIfInvalidSignature_installAccountOperatorPermitECDSA(
        uint privateKey,
        bytes memory operatorData,
        uint40 seed
    ) public {
        vm.assume(
            privateKey > 0 &&
                privateKey <
                115792089237316195423570985008687907852837564279074904382605163141518161494337
        );
        address alice = vm.addr(privateKey);
        address payable operator = payable(new Operator());
        vm.assume(uint160(address(operator)) != type(uint160).max);
        vm.assume(!cvc.haveCommonOwner(alice, operator));
        vm.assume(
            bytes4(operatorData) != 0xc41e79ed &&
                bytes4(operatorData) != 0xb79bb2d7 &&
                bytes4(operatorData) != 0x1234458c
        );
        vm.assume(seed > 0 && seed < type(uint40).max - 10);
        vm.warp(seed);

        Operator(operator).setExpectedHash(operatorData);

        signer.setPrivateKey(privateKey);

        bytes memory signature = signer.signPermit(
            address(uint160(alice) + 1),
            operator,
            operatorData,
            0,
            uint40(block.timestamp),
            uint40(block.timestamp)
        );
        vm.expectRevert(CreditVaultConnector.CVC_NotAuthorized.selector);
        cvc.installAccountOperatorPermitECDSA(
            alice,
            operator,
            operatorData,
            0,
            uint40(block.timestamp),
            uint40(block.timestamp),
            signature
        );

        signature = signer.signPermit(
            alice,
            address(uint160(address(operator)) + 1),
            operatorData,
            0,
            uint40(block.timestamp),
            uint40(block.timestamp)
        );
        vm.expectRevert(CreditVaultConnector.CVC_NotAuthorized.selector);
        cvc.installAccountOperatorPermitECDSA(
            alice,
            operator,
            operatorData,
            0,
            uint40(block.timestamp),
            uint40(block.timestamp),
            signature
        );

        signature = signer.signPermit(
            alice,
            operator,
            abi.encode(operatorData, "1"),
            0,
            uint40(block.timestamp),
            uint40(block.timestamp)
        );
        vm.expectRevert(CreditVaultConnector.CVC_NotAuthorized.selector);
        cvc.installAccountOperatorPermitECDSA(
            alice,
            operator,
            operatorData,
            0,
            uint40(block.timestamp),
            uint40(block.timestamp),
            signature
        );

        signature = signer.signPermit(
            alice,
            operator,
            operatorData,
            1,
            uint40(block.timestamp),
            uint40(block.timestamp)
        );
        vm.expectRevert(CreditVaultConnector.CVC_NotAuthorized.selector);
        cvc.installAccountOperatorPermitECDSA(
            alice,
            operator,
            operatorData,
            0,
            uint40(block.timestamp),
            uint40(block.timestamp),
            signature
        );

        signature = signer.signPermit(
            alice,
            operator,
            operatorData,
            0,
            uint40(block.timestamp + 1),
            uint40(block.timestamp)
        );
        vm.expectRevert(CreditVaultConnector.CVC_NotAuthorized.selector);
        cvc.installAccountOperatorPermitECDSA(
            alice,
            operator,
            operatorData,
            0,
            uint40(block.timestamp),
            uint40(block.timestamp),
            signature
        );

        signature = signer.signPermit(
            alice,
            operator,
            operatorData,
            0,
            uint40(block.timestamp),
            uint40(block.timestamp + 1)
        );
        vm.expectRevert(CreditVaultConnector.CVC_NotAuthorized.selector);
        cvc.installAccountOperatorPermitECDSA(
            alice,
            operator,
            operatorData,
            0,
            uint40(block.timestamp),
            uint40(block.timestamp),
            signature
        );

        // succeeds if signature is valid
        signature = signer.signPermit(
            alice,
            operator,
            operatorData,
            0,
            uint40(block.timestamp),
            uint40(block.timestamp)
        );
        cvc.installAccountOperatorPermitECDSA(
            alice,
            operator,
            operatorData,
            0,
            uint40(block.timestamp),
            uint40(block.timestamp),
            signature
        );

        vm.warp(block.timestamp + 1);
        signature = signer.signPermit(
            alice,
            operator,
            operatorData,
            0,
            uint40(block.timestamp),
            uint40(block.timestamp)
        );

        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(signature, 0x20))
            s := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }

        signature = abi.encodePacked(r, s, v, uint8(1));
        vm.expectRevert(CreditVaultConnector.CVC_InvalidSignature.selector);
        cvc.installAccountOperatorPermitECDSA(
            alice,
            operator,
            operatorData,
            0,
            uint40(block.timestamp),
            uint40(block.timestamp),
            signature
        );

        signature = abi.encodePacked(uint(0), s, v);
        vm.expectRevert(CreditVaultConnector.CVC_InvalidSignature.selector);
        cvc.installAccountOperatorPermitECDSA(
            alice,
            operator,
            operatorData,
            0,
            uint40(block.timestamp),
            uint40(block.timestamp),
            signature
        );

        signature = abi.encodePacked(r, uint(0), v);
        vm.expectRevert(CreditVaultConnector.CVC_InvalidSignature.selector);
        cvc.installAccountOperatorPermitECDSA(
            alice,
            operator,
            operatorData,
            0,
            uint40(block.timestamp),
            uint40(block.timestamp),
            signature
        );

        signature = abi.encodePacked(r, s, uint8(0));
        vm.expectRevert(CreditVaultConnector.CVC_InvalidSignature.selector);
        cvc.installAccountOperatorPermitECDSA(
            alice,
            operator,
            operatorData,
            0,
            uint40(block.timestamp),
            uint40(block.timestamp),
            signature
        );

        signature = abi.encodePacked(
            r,
            uint(
                0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A1
            ),
            v
        );
        vm.expectRevert(CreditVaultConnector.CVC_InvalidSignature.selector);
        cvc.installAccountOperatorPermitECDSA(
            alice,
            operator,
            operatorData,
            0,
            uint40(block.timestamp),
            uint40(block.timestamp),
            signature
        );
    }

    function test_RevertIfPermitInvalidated_installAccountOperatorPermitECDSA(
        uint privateKey,
        address operator,
        uint40 seed
    ) public {
        vm.assume(
            privateKey > 0 &&
                privateKey <
                115792089237316195423570985008687907852837564279074904382605163141518161494337
        );
        address alice = vm.addr(privateKey);
        vm.assume(uint160(operator) != type(uint160).max);
        vm.assume(!cvc.haveCommonOwner(alice, operator));
        vm.assume(seed > 0 && seed < type(uint40).max - 10);

        vm.warp(seed);
        signer.setPrivateKey(privateKey);
        bytes memory signature1 = signer.signPermit(
            alice,
            operator,
            bytes(""),
            0,
            uint40(block.timestamp),
            uint40(block.timestamp)
        );
        bytes memory signature2 = signer.signPermit(
            alice,
            address(uint160(operator) + 1),
            bytes(""),
            0,
            uint40(block.timestamp),
            uint40(block.timestamp)
        );

        vm.prank(alice);
        cvc.invalidateAllPermits();

        vm.expectRevert(CreditVaultConnector.CVC_InvalidTimestamp.selector);
        cvc.installAccountOperatorPermitECDSA(
            alice,
            operator,
            bytes(""),
            0,
            uint40(block.timestamp),
            uint40(block.timestamp),
            signature1
        );
        vm.expectRevert(CreditVaultConnector.CVC_InvalidTimestamp.selector);
        cvc.installAccountOperatorPermitECDSA(
            alice,
            address(uint160(operator) + 1),
            bytes(""),
            0,
            uint40(block.timestamp),
            uint40(block.timestamp),
            signature2
        );

        vm.warp(block.timestamp + 1);
        signature1 = signer.signPermit(
            alice,
            operator,
            bytes(""),
            0,
            uint40(block.timestamp),
            uint40(block.timestamp)
        );
        signature2 = signer.signPermit(
            alice,
            address(uint160(operator) + 1),
            bytes(""),
            0,
            uint40(block.timestamp),
            uint40(block.timestamp)
        );

        vm.prank(alice);
        cvc.invalidateAccountOperatorPermits(alice, operator);

        // only one permit is invalid
        vm.expectRevert(CreditVaultConnector.CVC_InvalidTimestamp.selector);
        cvc.installAccountOperatorPermitECDSA(
            alice,
            operator,
            bytes(""),
            0,
            uint40(block.timestamp),
            uint40(block.timestamp),
            signature1
        );
        cvc.installAccountOperatorPermitECDSA(
            alice,
            address(uint160(operator) + 1),
            bytes(""),
            0,
            uint40(block.timestamp),
            uint40(block.timestamp),
            signature2
        );

        // succeeds if permit is not invalidated
        vm.warp(block.timestamp + 1);
        signature1 = signer.signPermit(
            alice,
            operator,
            bytes(""),
            0,
            uint40(block.timestamp),
            uint40(block.timestamp)
        );
        cvc.installAccountOperatorPermitECDSA(
            alice,
            operator,
            bytes(""),
            0,
            uint40(block.timestamp),
            uint40(block.timestamp),
            signature1
        );

        // reverts if replayed
        vm.expectRevert(CreditVaultConnector.CVC_InvalidTimestamp.selector);
        cvc.installAccountOperatorPermitECDSA(
            alice,
            operator,
            bytes(""),
            0,
            uint40(block.timestamp),
            uint40(block.timestamp),
            signature1
        );
    }
}
