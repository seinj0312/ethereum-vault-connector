// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.20;

import "./Set.sol";
import "./Events.sol";
import "./Errors.sol";
import "./TransientStorage.sol";
import "./interfaces/ICreditVaultConnector.sol";
import "./interfaces/ICreditVault.sol";
import "./interfaces/IERC1271.sol";

/// @title CreditVaultConnector
/// @author Euler Labs (https://www.eulerlabs.com/)
/// @notice This contract implements the Credit Vault Connector.
contract CreditVaultConnector is Events, Errors, TransientStorage, ICVC {
    using ExecutionContext for EC;
    using Set for SetStorage;

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                       CONSTANTS                                           //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    string public constant name = "Credit Vault Connector";
    string public constant version = "1";

    bytes32 public constant PERMIT_TYPEHASH =
        keccak256(
            "Permit(address signer,uint nonceNamespace,uint nonce,uint deadline,uint value,bytes data)"
        );

    bytes32 internal constant TYPE_HASH =
        keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );

    bytes32 internal constant HASHED_NAME = keccak256(bytes(name));
    bytes32 internal constant HASHED_VERSION = keccak256(bytes(version));

    address internal constant ERC1820_REGISTRY =
        0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24;

    uint256 internal immutable CACHED_CHAIN_ID;
    bytes32 internal immutable CACHED_DOMAIN_SEPARATOR;

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                        STORAGE                                            //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    mapping(address account => SetStorage) internal accountCollaterals;
    mapping(address account => SetStorage) internal accountControllers;

    // Every Ethereum address has 256 accounts in the CVC (including the primary account - called the owner).
    // Each account has an account ID from 0-255, where 0 is the owner account's ID. In order to compute the account
    // addresses, the account ID is treated as a uint and XORed (exclusive ORed) with the Ethereum address.
    // In order to record the owner of a group of 256 accounts, the CVC uses a definition of a address prefix.
    // An address prefix is a part of an address having the first 19 bytes common with any of the 256 account
    // addresses belonging to the same group.
    // account/152 -> prefix/152
    // To get an address prefix for the account, it's enough to take the account address and right shift it by 8 bits.

    mapping(uint152 addressPrefix => address owner) internal ownerLookup;

    mapping(uint152 addressPrefix => mapping(uint nonceNamespace => uint nonce))
        internal nonceLookup;

    mapping(uint152 addressPrefix => mapping(address operator => uint accountOperatorAuthorized))
        internal operatorLookup;

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                CONSTRUCTOR, FALLBACKS                                     //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    constructor() {
        CACHED_CHAIN_ID = block.chainid;
        CACHED_DOMAIN_SEPARATOR = calculateDomainSeparator();
    }

    receive() external payable {}

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                       MODIFIERS                                           //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice A modifier that allows only the address recorded as an owner of the address prefix to call the function.
    /// @dev The owner of an address prefix is an address that matches the address that has previously been recorded (or will be) as an owner in the ownerLookup. In case of the self-call in the permit() function, the CVC address becomes msg.sender hence the "true" caller address (that is permit message signer) is taken from the execution context.
    /// @param addressPrefix The address prefix for which it is checked whether the caller is the owner.
    modifier onlyOwner(uint152 addressPrefix) virtual {
        {
            // calculate a phantom address from the address prefix which can be used as an input to internal functions
            address account = address(uint160(addressPrefix) << 8);

            // CVC can only be msg.sender during the self-call in the permit() function. in that case,
            // the "true" sender address (that is the permit message signer) is taken from the execution context
            address msgSender = address(this) == msg.sender
                ? executionContext.getOnBehalfOfAccount()
                : msg.sender;

            if (haveCommonOwnerInternal(account, msgSender)) {
                address owner = getAccountOwnerInternal(account);

                if (owner == address(0)) {
                    setAccountOwnerInternal(account, msgSender);
                } else if (owner != msgSender) {
                    revert CVC_NotAuthorized();
                }
            } else {
                revert CVC_NotAuthorized();
            }
        }

        _;
    }

    /// @notice A modifier that allows only the owner or an operator of the account to call the function.
    /// @dev The owner of an account is an address that matches first 19 bytes of the account address and has been recorded (or will be) as an owner in the ownerLookup. An operator of an account is an address that has been authorized by the owner of an account to perform operations on behalf of the owner. In case of the self-call in the permit() function, the CVC address becomes msg.sender hence the "true" caller address (that is permit message signer) is taken from the execution context.
    /// @param account The address of the account for which it is checked whether the caller is the owner or an operator.
    modifier onlyOwnerOrOperator(address account) virtual {
        {
            // CVC can only be msg.sender during the self-call in the permit() function. in that case,
            // the "true" sender address (that is the permit message signer) is taken from the execution context
            address msgSender = address(this) == msg.sender
                ? executionContext.getOnBehalfOfAccount()
                : msg.sender;

            if (haveCommonOwnerInternal(account, msgSender)) {
                address owner = getAccountOwnerInternal(account);

                if (owner == address(0)) {
                    setAccountOwnerInternal(account, msgSender);
                } else if (owner != msgSender) {
                    revert CVC_NotAuthorized();
                }
            } else if (
                !isAccountOperatorAuthorizedInternal(account, msgSender)
            ) {
                revert CVC_NotAuthorized();
            }
        }

        _;
    }

    /// @notice A modifier checks whether msg.sender is the only controller for the account.
    modifier onlyController(address account) {
        {
            uint numOfControllers = accountControllers[account].numElements;
            address controller = accountControllers[account].firstElement;

            if (numOfControllers != 1) {
                revert CVC_ControllerViolation();
            }

            if (controller != msg.sender) {
                revert CVC_NotAuthorized();
            }
        }

        _;
    }

    /// @notice A modifier that verifies whether account or vault status checks are reentered as well as checks for impersonate reentrancy.
    modifier nonReentrant() {
        {
            EC context = executionContext;

            if (context.areChecksInProgress()) {
                revert CVC_ChecksReentrancy();
            }

            if (context.isImpersonationInProgress()) {
                revert CVC_ImpersonateReentrancy();
            }
        }

        _;
    }

    /// @notice A modifier that verifies whether account or vault status checks are reentered and sets the lock.
    modifier nonReentrantChecks() virtual {
        EC contextCache = executionContext;

        if (contextCache.areChecksInProgress()) {
            revert CVC_ChecksReentrancy();
        }

        executionContext = contextCache
            .setChecksInProgress()
            .setOnBehalfOfAccount(address(0));

        _;

        executionContext = contextCache;
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                   PUBLIC FUNCTIONS                                        //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    // Execution internals

    /// @inheritdoc ICVC
    function getRawExecutionContext() external view returns (uint context) {
        context = EC.unwrap(executionContext);
    }

    /// @inheritdoc ICVC
    function getCurrentCallDepth() external view returns (uint) {
        return executionContext.getCallDepth();
    }

    /// @inheritdoc ICVC
    function getCurrentOnBehalfOfAccount(
        address controllerToCheck
    ) public view returns (address onBehalfOfAccount, bool controllerEnabled) {
        onBehalfOfAccount = executionContext.getOnBehalfOfAccount();

        // for safety, revert if no account has been auhenticated
        if (onBehalfOfAccount == address(0)) {
            revert CVC_OnBehalfOfAccountNotAuthenticated();
        }

        controllerEnabled = controllerToCheck == address(0)
            ? false
            : accountControllers[onBehalfOfAccount].contains(controllerToCheck);
    }

    /// @inheritdoc ICVC
    function areChecksInProgress() external view returns (bool) {
        return executionContext.areChecksInProgress();
    }

    /// @inheritdoc ICVC
    function isImpersonationInProgress() external view returns (bool) {
        return executionContext.isImpersonationInProgress();
    }

    /// @inheritdoc ICVC
    function isOperatorAuthenticated() external view returns (bool) {
        return executionContext.isOperatorAuthenticated();
    }

    /// @inheritdoc ICVC
    function isSimulationInProgress() external view returns (bool) {
        return executionContext.isSimulationInProgress();
    }

    // Owners and operators

    /// @inheritdoc ICVC
    function haveCommonOwner(
        address account,
        address otherAccount
    ) external pure returns (bool) {
        return haveCommonOwnerInternal(account, otherAccount);
    }

    /// @inheritdoc ICVC
    function getAddressPrefix(address account) external pure returns (uint152) {
        return getAddressPrefixInternal(account);
    }

    /// @inheritdoc ICVC
    function getAccountOwner(
        address account
    ) external view returns (address owner) {
        owner = getAccountOwnerInternal(account);

        if (owner == address(0)) revert CVC_AccountOwnerNotRegistered();
    }

    /// @inheritdoc ICVC
    function getNonce(
        uint152 addressPrefix,
        uint nonceNamespace
    ) external view returns (uint) {
        return nonceLookup[addressPrefix][nonceNamespace];
    }

    /// @inheritdoc ICVC
    function getOperator(
        uint152 addressPrefix,
        address operator
    ) external view returns (uint accountOperatorAuthorized) {
        return operatorLookup[addressPrefix][operator];
    }

    /// @inheritdoc ICVC
    function isAccountOperatorAuthorized(
        address account,
        address operator
    ) external view returns (bool authorized) {
        return isAccountOperatorAuthorizedInternal(account, operator);
    }

    /// @inheritdoc ICVC
    function setNonce(
        uint152 addressPrefix,
        uint nonceNamespace,
        uint nonce
    ) public payable virtual onlyOwner(addressPrefix) {
        if (nonceLookup[addressPrefix][nonceNamespace] >= nonce) {
            revert CVC_InvalidNonce();
        }

        nonceLookup[addressPrefix][nonceNamespace] = nonce;
        emit NonceUsed(addressPrefix, nonce);
    }

    /// @inheritdoc ICVC
    function setOperator(
        uint152 addressPrefix,
        address operator,
        uint accountOperatorAuthorized
    ) public payable virtual onlyOwner(addressPrefix) {
        // if CVC is msg.sender (during the self-call in the permit() function), the owner address will
        // be taken from the storage which must be storing the correct owner address
        address owner = address(this) == msg.sender
            ? ownerLookup[addressPrefix]
            : msg.sender;

        // the operator can neither be zero address nor can belong to one of 256 accounts of the owner
        if (
            operator == address(0) || haveCommonOwnerInternal(owner, operator)
        ) {
            revert CVC_InvalidAddress();
        }

        if (
            operatorLookup[addressPrefix][operator] == accountOperatorAuthorized
        ) {
            revert CVC_InvalidOperatorStatus();
        } else {
            operatorLookup[addressPrefix][operator] = accountOperatorAuthorized;

            emit OperatorStatus(
                addressPrefix,
                operator,
                accountOperatorAuthorized
            );
        }
    }

    /// @inheritdoc ICVC
    function setAccountOperator(
        address account,
        address operator,
        bool authorized
    ) public payable virtual onlyOwnerOrOperator(account) {
        // if CVC is msg.sender (during the self-call in the permit() function), it won't have the common owner
        // with the account as it would mean that the CVC itself signed the ERC-1271 message which is not
        // possible. hence in that case, the owner address will be taken from the storage which
        // must be storing the correct owner address
        address owner = haveCommonOwnerInternal(account, msg.sender)
            ? msg.sender
            : getAccountOwnerInternal(account);

        // if CVC is msg.sender (during the self-call in the permit() function), it acts as if it
        // was an owner, meaning it can authorize and deauthorize operators as per signed data.
        // if it's an operator calling, it can only make changes for itself hence must be equal to msg.sender
        if (
            owner != msg.sender &&
            operator != msg.sender &&
            address(this) != msg.sender
        ) {
            revert CVC_NotAuthorized();
        }

        // the operator can neither be zero address nor can belong to one of 256 accounts of the owner
        if (
            operator == address(0) || haveCommonOwnerInternal(owner, operator)
        ) {
            revert CVC_InvalidAddress();
        }

        uint152 addressPrefix = getAddressPrefixInternal(account);
        uint bitMask = 1 << (uint160(owner) ^ uint160(account));
        uint oldAccountOperatorAuthorized = operatorLookup[addressPrefix][
            operator
        ];
        uint newAccountOperatorAuthorized = authorized
            ? oldAccountOperatorAuthorized | bitMask
            : oldAccountOperatorAuthorized & ~bitMask;

        if (oldAccountOperatorAuthorized == newAccountOperatorAuthorized) {
            revert CVC_InvalidOperatorStatus();
        } else {
            operatorLookup[addressPrefix][
                operator
            ] = newAccountOperatorAuthorized;

            emit OperatorStatus(
                addressPrefix,
                operator,
                newAccountOperatorAuthorized
            );
        }
    }

    // Collaterals management

    /// @inheritdoc ICVC
    function getCollaterals(
        address account
    ) external view returns (address[] memory) {
        return accountCollaterals[account].get();
    }

    /// @inheritdoc ICVC
    function isCollateralEnabled(
        address account,
        address vault
    ) external view returns (bool) {
        return accountCollaterals[account].contains(vault);
    }

    /// @inheritdoc ICVC
    function enableCollateral(
        address account,
        address vault
    ) public payable virtual nonReentrant onlyOwnerOrOperator(account) {
        if (vault == address(this)) revert CVC_InvalidAddress();

        if (accountCollaterals[account].insert(vault)) {
            emit CollateralStatus(account, vault, true);
        }
        requireAccountStatusCheck(account);
    }

    /// @inheritdoc ICVC
    function disableCollateral(
        address account,
        address vault
    ) public payable virtual nonReentrant onlyOwnerOrOperator(account) {
        if (accountCollaterals[account].remove(vault)) {
            emit CollateralStatus(account, vault, false);
        }
        requireAccountStatusCheck(account);
    }

    // Controllers management

    /// @inheritdoc ICVC
    function getControllers(
        address account
    ) external view returns (address[] memory) {
        return accountControllers[account].get();
    }

    /// @inheritdoc ICVC
    function isControllerEnabled(
        address account,
        address vault
    ) external view returns (bool) {
        return accountControllers[account].contains(vault);
    }

    /// @inheritdoc ICVC
    function enableController(
        address account,
        address vault
    ) public payable virtual nonReentrant onlyOwnerOrOperator(account) {
        if (vault == address(this)) revert CVC_InvalidAddress();

        if (accountControllers[account].insert(vault)) {
            emit ControllerStatus(account, vault, true);
        }
        requireAccountStatusCheck(account);
    }

    /// @inheritdoc ICVC
    function disableController(
        address account
    ) public payable virtual nonReentrant {
        if (accountControllers[account].remove(msg.sender)) {
            emit ControllerStatus(account, msg.sender, false);
        }
        requireAccountStatusCheck(account);
    }

    // Permit

    /// @inheritdoc ICVC
    function permit(
        address signer,
        uint nonceNamespace,
        uint nonce,
        uint deadline,
        uint value,
        bytes calldata data,
        bytes calldata signature
    ) public payable virtual nonReentrant {
        uint152 addressPrefix = getAddressPrefixInternal(signer);

        if (signer == address(0) || !isSignerValid(signer)) {
            revert CVC_InvalidAddress();
        }

        if (
            nonce == type(uint256).max ||
            ++nonceLookup[addressPrefix][nonceNamespace] != nonce
        ) {
            revert CVC_InvalidNonce();
        }

        if (deadline < block.timestamp) {
            revert CVC_InvalidTimestamp();
        }

        if (data.length == 0) {
            revert CVC_InvalidData();
        }

        bytes32 permitHash = getPermitHash(
            signer,
            nonceNamespace,
            nonce,
            deadline,
            value,
            data
        );

        if (
            signer != recoverECDSASigner(permitHash, signature) &&
            !isValidERC1271Signature(signer, permitHash, signature)
        ) {
            revert CVC_NotAuthorized();
        }

        emit NonceUsed(addressPrefix, nonce);

        // CVC address becomes msg.sender for the duration this self-call
        (bool success, bytes memory result) = callWithContextInternal(
            address(this),
            signer,
            value,
            data
        );

        if (!success) {
            revertBytes(result);
        }
    }

    // Calls forwarding

    /// @inheritdoc ICVC
    function callback(
        address onBehalfOfAccount,
        uint value,
        bytes calldata data
    ) public payable virtual nonReentrant returns (bytes memory result) {
        // cannot be called within the self-call of the permit()
        if (address(this) == msg.sender) {
            revert CVC_NotAuthorized();
        }

        EC contextCache = executionContext;
        executionContext = contextCache.increaseCallDepth();

        // call back into the msg.sender with the context set
        bool success;
        (success, result) = callWithContextInternal(
            msg.sender,
            onBehalfOfAccount,
            value,
            data
        );

        if (!success) {
            revertBytes(result);
        }

        if (!contextCache.areChecksDeferred()) {
            executionContext = contextCache.setChecksInProgress();

            checkStatusAll(SetType.Account);
            checkStatusAll(SetType.Vault);
        }

        executionContext = contextCache;
    }

    /// @inheritdoc ICVC
    function call(
        address targetContract,
        address onBehalfOfAccount,
        uint value,
        bytes calldata data
    ) public payable virtual nonReentrant returns (bytes memory result) {
        if (address(this) == targetContract || msg.sender == targetContract) {
            revert CVC_InvalidAddress();
        }

        EC contextCache = executionContext;
        executionContext = contextCache.increaseCallDepth();

        bool success;
        (success, result) = callInternal(
            targetContract,
            onBehalfOfAccount,
            value,
            data
        );

        if (!success) {
            revertBytes(result);
        }

        if (!contextCache.areChecksDeferred()) {
            executionContext = contextCache.setChecksInProgress();

            checkStatusAll(SetType.Account);
            checkStatusAll(SetType.Vault);
        }

        executionContext = contextCache;
    }

    /// @inheritdoc ICVC
    function impersonate(
        address targetCollateral,
        address onBehalfOfAccount,
        uint value,
        bytes calldata data
    ) public payable virtual nonReentrant returns (bytes memory result) {
        if (address(this) == targetCollateral) {
            revert CVC_InvalidAddress();
        }

        EC contextCache = executionContext;
        executionContext = contextCache
            .increaseCallDepth()
            .setImpersonationInProgress();

        bool success;
        (success, result) = impersonateInternal(
            targetCollateral,
            onBehalfOfAccount,
            value,
            data
        );

        if (!success) {
            revertBytes(result);
        }

        if (!contextCache.areChecksDeferred()) {
            executionContext = contextCache.setChecksInProgress();

            checkStatusAll(SetType.Account);
            checkStatusAll(SetType.Vault);
        }

        executionContext = contextCache;
    }

    /// @inheritdoc ICVC
    function batch(
        BatchItem[] calldata items
    ) public payable virtual nonReentrant {
        EC contextCache = executionContext;
        executionContext = contextCache.increaseCallDepth();

        batchInternal(items);

        if (!contextCache.areChecksDeferred()) {
            executionContext = contextCache.setChecksInProgress();

            checkStatusAll(SetType.Account);
            checkStatusAll(SetType.Vault);
        }

        executionContext = contextCache;
    }

    // Simulations

    /// @inheritdoc ICVC
    function batchRevert(
        BatchItem[] calldata items
    ) public payable virtual nonReentrant {
        BatchItemResult[] memory batchItemsResult;
        BatchItemResult[] memory accountsStatusResult;
        BatchItemResult[] memory vaultsStatusResult;

        EC contextCache = executionContext;

        if (contextCache.areChecksDeferred()) {
            revert CVC_SimulationBatchNested();
        }

        executionContext = contextCache
            .increaseCallDepth()
            .setSimulationInProgress();

        batchItemsResult = batchInternalWithResult(items);

        executionContext = contextCache.setChecksInProgress();

        accountsStatusResult = checkStatusAllWithResult(SetType.Account);
        vaultsStatusResult = checkStatusAllWithResult(SetType.Vault);

        executionContext = contextCache;

        revert CVC_RevertedBatchResult(
            batchItemsResult,
            accountsStatusResult,
            vaultsStatusResult
        );
    }

    /// @inheritdoc ICVC
    function batchSimulation(
        BatchItem[] calldata items
    )
        public
        payable
        virtual
        returns (
            BatchItemResult[] memory batchItemsResult,
            BatchItemResult[] memory accountsStatusResult,
            BatchItemResult[] memory vaultsStatusResult
        )
    {
        (bool success, bytes memory result) = address(this).delegatecall(
            abi.encodeCall(this.batchRevert, items)
        );

        if (success) {
            revert CVC_BatchPanic();
        } else if (bytes4(result) != CVC_RevertedBatchResult.selector) {
            revertBytes(result);
        }

        assembly {
            result := add(result, 4)
        }

        (batchItemsResult, accountsStatusResult, vaultsStatusResult) = abi
            .decode(
                result,
                (BatchItemResult[], BatchItemResult[], BatchItemResult[])
            );
    }

    // Account Status Check

    /// @inheritdoc ICVC
    function isAccountStatusCheckDeferred(
        address account
    ) external view returns (bool) {
        return accountStatusChecks.contains(account);
    }

    /// @inheritdoc ICVC
    function requireAccountStatusCheck(
        address account
    ) public payable virtual nonReentrantChecks {
        if (executionContext.areChecksDeferred()) {
            accountStatusChecks.insert(account);
        } else {
            requireAccountStatusCheckInternal(account);
        }
    }

    /// @inheritdoc ICVC
    function requireAccountStatusCheckNow(
        address account
    ) public payable virtual nonReentrantChecks {
        accountStatusChecks.remove(account);
        requireAccountStatusCheckInternal(account);
    }

    /// @inheritdoc ICVC
    function requireAllAccountsStatusCheckNow()
        public
        payable
        virtual
        nonReentrantChecks
    {
        checkStatusAll(SetType.Account);
    }

    /// @inheritdoc ICVC
    function forgiveAccountStatusCheck(
        address account
    ) public payable virtual nonReentrantChecks onlyController(account) {
        accountStatusChecks.remove(account);
    }

    // Vault Status Check

    /// @inheritdoc ICVC
    function isVaultStatusCheckDeferred(
        address vault
    ) external view returns (bool) {
        return vaultStatusChecks.contains(vault);
    }

    /// @inheritdoc ICVC
    function requireVaultStatusCheck()
        public
        payable
        virtual
        nonReentrantChecks
    {
        if (executionContext.areChecksDeferred()) {
            vaultStatusChecks.insert(msg.sender);
        } else {
            requireVaultStatusCheckInternal(msg.sender);
        }
    }

    /// @inheritdoc ICVC
    function requireVaultStatusCheckNow()
        public
        payable
        virtual
        nonReentrantChecks
    {
        vaultStatusChecks.remove(msg.sender);
        requireVaultStatusCheckInternal(msg.sender);
    }

    /// @inheritdoc ICVC
    function requireAllVaultsStatusCheckNow()
        public
        payable
        virtual
        nonReentrantChecks
    {
        checkStatusAll(SetType.Vault);
    }

    /// @inheritdoc ICVC
    function forgiveVaultStatusCheck()
        public
        payable
        virtual
        nonReentrantChecks
    {
        vaultStatusChecks.remove(msg.sender);
    }

    /// @inheritdoc ICVC
    function requireAccountAndVaultStatusCheck(
        address account
    ) public payable virtual nonReentrantChecks {
        if (executionContext.areChecksDeferred()) {
            accountStatusChecks.insert(account);
            vaultStatusChecks.insert(msg.sender);
        } else {
            requireAccountStatusCheckInternal(account);
            requireVaultStatusCheckInternal(msg.sender);
        }
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                  INTERNAL FUNCTIONS                                       //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function callWithContextInternal(
        address targetContract,
        address onBehalfOfAccount,
        uint value,
        bytes calldata data
    ) internal virtual returns (bool success, bytes memory result) {
        if (
            value > 0 &&
            value != type(uint).max &&
            value > address(this).balance
        ) {
            revert CVC_InvalidValue();
        } else if (value == type(uint).max) {
            value = address(this).balance;
        }

        emit CallWithContext(
            msg.sender,
            targetContract,
            onBehalfOfAccount,
            bytes4(data)
        );

        EC contextCache = executionContext;

        // CVC can only be msg.sender after the self-call in the permit() function. in that case,
        // the "true" sender address (that is the permit message signer) is taken from the execution context
        address msgSender = address(this) == msg.sender
            ? contextCache.getOnBehalfOfAccount()
            : msg.sender;

        // set the onBehalfOfAccount in the execution context for the duration of the external call.
        // considering that the operatorAuthenticated is only meant to be observable by external
        // contracts, it is sufficient to set it here rather than in the onlyOwner and onlyOwnerOrOperator
        // modifiers.
        // apart from the usual scenario (when an owner operates on behalf of its account),
        // the operatorAuthenticated should be cleared when about to execute the permit self-call or a callback
        if (
            haveCommonOwnerInternal(onBehalfOfAccount, msgSender) ||
            address(this) == targetContract ||
            msg.sender == targetContract
        ) {
            executionContext = contextCache
                .setOnBehalfOfAccount(onBehalfOfAccount)
                .clearOperatorAuthenticated();
        } else {
            executionContext = contextCache
                .setOnBehalfOfAccount(onBehalfOfAccount)
                .setOperatorAuthenticated();
        }

        (success, result) = targetContract.call{value: value}(data);

        executionContext = contextCache;
    }

    function callInternal(
        address targetContract,
        address onBehalfOfAccount,
        uint value,
        bytes calldata data
    )
        internal
        virtual
        onlyOwnerOrOperator(onBehalfOfAccount)
        returns (bool success, bytes memory result)
    {
        if (targetContract == ERC1820_REGISTRY) {
            revert CVC_InvalidAddress();
        }

        (success, result) = callWithContextInternal(
            targetContract,
            onBehalfOfAccount,
            value,
            data
        );
    }

    function impersonateInternal(
        address targetCollateral,
        address onBehalfOfAccount,
        uint value,
        bytes calldata data
    )
        internal
        virtual
        onlyController(onBehalfOfAccount)
        returns (bool success, bytes memory result)
    {
        if (!accountCollaterals[onBehalfOfAccount].contains(targetCollateral)) {
            revert CVC_NotAuthorized();
        }

        (success, result) = callWithContextInternal(
            targetCollateral,
            onBehalfOfAccount,
            value,
            data
        );
    }

    function callBatchItemInternal(
        BatchItem calldata item
    ) internal returns (bool success, bytes memory result) {
        if (item.targetContract == address(this)) {
            // delegatecall is used here to preserve msg.sender in order
            // to be able to perform authentication
            (success, result) = address(this).delegatecall(item.data);
        } else {
            (success, result) = callInternal(
                item.targetContract,
                item.onBehalfOfAccount,
                item.value,
                item.data
            );
        }
    }

    function batchInternal(BatchItem[] calldata items) internal {
        uint length = items.length;

        for (uint i; i < length; ) {
            (bool success, bytes memory result) = callBatchItemInternal(
                items[i]
            );

            if (!success) {
                revertBytes(result);
            }

            unchecked {
                ++i;
            }
        }
    }

    function batchInternalWithResult(
        BatchItem[] calldata items
    ) internal returns (BatchItemResult[] memory batchItemsResult) {
        uint length = items.length;
        batchItemsResult = new BatchItemResult[](length);

        for (uint i; i < length; ) {
            (
                batchItemsResult[i].success,
                batchItemsResult[i].result
            ) = callBatchItemInternal(items[i]);

            unchecked {
                ++i;
            }
        }
    }

    function checkAccountStatusInternal(
        address account
    ) internal virtual returns (bool isValid, bytes memory result) {
        uint numOfControllers = accountControllers[account].numElements;
        address controller = accountControllers[account].firstElement;

        if (numOfControllers == 0) return (true, "");
        else if (numOfControllers > 1) revert CVC_ControllerViolation();

        bool success;
        (success, result) = controller.call(
            abi.encodeCall(
                ICreditVault.checkAccountStatus,
                (account, accountCollaterals[account].get())
            )
        );

        isValid =
            success &&
            result.length == 32 &&
            abi.decode(result, (bytes32)) ==
            bytes32(ICreditVault.checkAccountStatus.selector);
    }

    function requireAccountStatusCheckInternal(
        address account
    ) internal virtual {
        (bool isValid, bytes memory result) = checkAccountStatusInternal(
            account
        );

        if (!isValid) {
            revertBytes(result);
        }
    }

    function checkVaultStatusInternal(
        address vault
    ) internal returns (bool isValid, bytes memory result) {
        bool success;
        (success, result) = vault.call(
            abi.encodeCall(ICreditVault.checkVaultStatus, ())
        );

        isValid =
            success &&
            result.length == 32 &&
            abi.decode(result, (bytes32)) ==
            bytes32(ICreditVault.checkVaultStatus.selector);
    }

    function requireVaultStatusCheckInternal(address vault) internal virtual {
        (bool isValid, bytes memory result) = checkVaultStatusInternal(vault);

        if (!isValid) {
            revertBytes(result);
        }
    }

    function checkStatusAll(SetType setType) internal virtual {
        setType == SetType.Account
            ? accountStatusChecks.forEachAndClear(
                requireAccountStatusCheckInternal
            )
            : vaultStatusChecks.forEachAndClear(
                requireVaultStatusCheckInternal
            );
    }

    function checkStatusAllWithResult(
        SetType setType
    ) internal virtual returns (BatchItemResult[] memory checksResult) {
        bytes[] memory callbackResult = setType == SetType.Account
            ? accountStatusChecks.forEachAndClearWithResult(
                checkAccountStatusInternal
            )
            : vaultStatusChecks.forEachAndClearWithResult(
                checkVaultStatusInternal
            );

        uint length = callbackResult.length;
        checksResult = new BatchItemResult[](length);

        for (uint i; i < length; ) {
            (bool isValid, bytes memory result) = abi.decode(
                callbackResult[i],
                (bool, bytes)
            );
            checksResult[i] = BatchItemResult(isValid, result);

            unchecked {
                ++i;
            }
        }
    }

    // Permit-related functions

    function isSignerValid(
        address signer
    ) internal pure returns (bool isValid) {
        // not valid if the signer address falls into any of the precompiles/predeploys
        // addresses space (depends on the chain ID).
        // IMPORTANT: revisit this logic when deploying on chains other than the Ethereum mainnet
        return !haveCommonOwnerInternal(signer, address(0));
    }

    function getPermitHash(
        address signer,
        uint nonceNamespace,
        uint nonce,
        uint deadline,
        uint value,
        bytes calldata data
    ) internal view returns (bytes32 permitHash) {
        bytes32 domainSeparator = block.chainid == CACHED_CHAIN_ID
            ? CACHED_DOMAIN_SEPARATOR
            : calculateDomainSeparator();

        bytes32 structHash = keccak256(
            abi.encode(
                PERMIT_TYPEHASH,
                signer,
                nonceNamespace,
                nonce,
                deadline,
                value,
                keccak256(data)
            )
        );

        assembly ("memory-safe") {
            mstore(0x00, "\x19\x01")
            mstore(0x02, domainSeparator)
            mstore(0x22, structHash)
            permitHash := keccak256(0x00, 0x42)
            mstore(0x22, 0)
        }
    }

    // Based on:
    // https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/utils/cryptography/ECDSA.sol
    // Note that the function returns zero address if the signature is invalid hence the result always has to be
    // checked against address zero.
    function recoverECDSASigner(
        bytes32 hash,
        bytes memory signature
    ) internal pure returns (address signer) {
        if (signature.length != 65) return address(0);

        bytes32 r;
        bytes32 s;
        uint8 v;

        // ecrecover takes the signature parameters, and the only way to get them
        // currently is to use assembly.
        /// @solidity memory-safe-assembly
        assembly {
            r := mload(add(signature, 0x20))
            s := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }

        // EIP-2 still allows signature malleability for ecrecover(). Remove this possibility and make the signature
        // unique. Appendix F in the Ethereum Yellow paper (https://ethereum.github.io/yellowpaper/paper.pdf), defines
        // the valid range for s in (301): 0 < s < secp256k1n ÷ 2 + 1, and for v in (302): v ∈ {27, 28}. Most
        // signatures from current libraries generate a unique signature with an s-value in the lower half order.
        //
        // If your library generates malleable signatures, such as s-values in the upper range, calculate a new s-value
        // with 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141 - s1 and flip v from 27 to 28 or
        // vice versa. If your library also generates signatures with 0/1 for v instead 27/28, add 27 to v to accept
        // these malleable signatures as well.
        if (
            uint256(s) >
            0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0
        ) {
            return address(0);
        }

        // return the signer address (note that it might be zero address)
        signer = ecrecover(hash, v, r, s);
    }

    // Based on:
    // https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/utils/cryptography/SignatureChecker.sol
    function isValidERC1271Signature(
        address signer,
        bytes32 hash,
        bytes memory signature
    ) internal view returns (bool isValid) {
        if (signer.code.length == 0) return false;

        (bool success, bytes memory result) = signer.staticcall(
            abi.encodeCall(IERC1271.isValidSignature, (hash, signature))
        );

        isValid =
            success &&
            result.length == 32 &&
            abi.decode(result, (bytes32)) ==
            bytes32(IERC1271.isValidSignature.selector);
    }

    function calculateDomainSeparator() internal view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    TYPE_HASH,
                    HASHED_NAME,
                    HASHED_VERSION,
                    block.chainid,
                    address(this)
                )
            );
    }

    // Auxiliary functions

    function haveCommonOwnerInternal(
        address account,
        address otherAccount
    ) internal pure returns (bool result) {
        assembly {
            result := lt(xor(account, otherAccount), 0x100)
        }
    }

    function getAddressPrefixInternal(
        address account
    ) internal pure returns (uint152) {
        return uint152(uint160(account) >> 8);
    }

    function getAccountOwnerInternal(
        address account
    ) internal view returns (address) {
        uint152 addressPrefix = getAddressPrefixInternal(account);
        return ownerLookup[addressPrefix];
    }

    function isAccountOperatorAuthorizedInternal(
        address account,
        address operator
    ) internal view returns (bool isAuthorized) {
        address owner = getAccountOwnerInternal(account);

        // if the owner is not registered yet, it means that the operator couldn't have been authorized
        if (owner == address(0)) return false;

        uint152 addressPrefix = getAddressPrefixInternal(account);
        uint bitMask = 1 << (uint160(owner) ^ uint160(account));

        return operatorLookup[addressPrefix][operator] & bitMask != 0;
    }

    function setAccountOwnerInternal(address account, address owner) internal {
        uint152 addressPrefix = getAddressPrefixInternal(account);
        ownerLookup[addressPrefix] = owner;
        emit OwnerRegistered(addressPrefix, owner);
    }

    function revertBytes(bytes memory errMsg) internal pure {
        if (errMsg.length != 0) {
            assembly {
                revert(add(32, errMsg), mload(errMsg))
            }
        }
        revert CVC_EmptyError();
    }
}
