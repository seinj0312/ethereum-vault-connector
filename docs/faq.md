# Frequently Asked Questions (FAQ)

<!-- TOC FOLLOWS -->
<!-- START OF TOC -->

* [What is the Ethereum Vault Connector?](#what-is-the-ethereum-vault-connector)
* [How does the EVC work in principle?](#how-does-the-evc-work-in-principle)
* [What are the benefits of building on the EVC?](#what-are-the-benefits-of-building-on-the-evc)
* [What can be built using the EVC?](#what-can-be-built-using-the-evc)
* [What is a Controller in the context of EVC?](#what-is-a-controller-in-the-context-of-evc)
* [What are Account Status Checks?](#what-are-account-status-checks)
* [What are Vault Status Checks?](#what-are-vault-status-checks)
* [What are checks deferrals and how do they work?](#what-are-checks-deferrals-and-how-do-they-work)
* [What is an Operator?](#what-is-an-operator)
* [What is the concept of sub-accounts in the EVC?](#what-is-the-concept-of-sub-accounts-in-the-evc)
* [What is the purpose of the `batch` function in the EVC?](#what-is-the-purpose-of-the-batch-function-in-the-evc)
* [How does the EVC handle gasless transactions?](#how-does-the-evc-handle-gasless-transactions)
* [How does the EVC support simulations?](#how-does-the-evc-support-simulations)
* [What is the purpose of the `impersonate` function in the EVC?](#what-is-the-purpose-of-the-`impersonate`-function-in-the-evc)
* [How does the EVC interact with other smart contracts?](#how-does-the-evc-interact-with-other-smart-contracts)

<!-- END OF TOC -->

## What is the Ethereum Vault Connector?

The Ethereum Vault Connector (EVC) is a foundational layer designed to facilitate the core functionality required for a lending market. It serves as a base building block for various protocols, providing a robust and flexible framework for developers to build upon. The EVC primarily mediates between vaults, contracts that implement the [ERC-4626](https://ethereum.org/en/developers/docs/standards/tokens/erc-4626/) interface and contain additional logic for interfacing with other vaults.

## How does the EVC work in principle?

When a user wishes to borrow, they must link their accounts and collateral vaults to the borrowed-from vault via the EVC. The liability vault, also known as the "controller", is then consulted whenever a user wants to perform an action potentially impacting account's solvency, such as withdrawing collateral. The EVC is responsible for calling the controller which determines whether the action is allowed or if it should be blocked to prevent account insolvency.

## What are the benefits of building on the EVC?

The EVC contains the functionality required to build flexible products, both for EOAs and smart contracts. It provides a common base ecosystem and reduces complexity in the core lending/borrowing contracts, allowing them to focus on their differentiating factors such as pricing and risk management.

The EVC helps create the network effect by offering the access to unified liquidity and interoperability, allowing protocols to recognize deposits in other vaults as collateral. It does not enforce specific properties about the assets and provides a standardized approach to account liquidity checks and vault constraints enforcement. Lastly, amongst others, the EVC supports batch operations, sub-accounts, checks deferrals, automations, gasless transactions, and provides an interface for simulating operations.

## What can be built using the EVC?

The EVC provides a robust and flexible framework for developers to build a variety of new products. These include but are not limited to:

1. Traditional, overcollateralized lending products
1. Uncollateralized lending products
1. Real World Assets (RWA) lending products
1. NFT lending products
1. P2P lending products
1. Oracle-free lending products
1. Lending products based on alternate oracles
1. Novel risk management solutions
1. Novel interest rate models
1. Transaction relayers
1. Intent-based systems
1. Automations (conditional orders, custom liquidation flows, strategies, position managers, optimizers, guardians etc.)
1. Smart contract tooling (i.e. swap hubs using new dexes or new dex aggregators)
1. Integrations

These are just a few examples of what can be built using the EVC. The possibilities are vast and limited only by the creativity and ingenuity of the developer community.

## What is a Controller in the context of EVC?

In the context of the EVC, a Controller is a type of Vault that a user enables in order to borrow from it. When a user enables a Controller Vault, they submit their account to the rules encoded in the Controller Vault's code. The Controller Vault indirectly controls all the funds in all the enabled Collateral Vaults of the user. Whenever a user wants to perform an action such as removing collateral, the Controller Vault is consulted to determine whether the action is allowed, or whether it should be blocked since it would make the account insolvent.
The Controller Vault plays a crucial role in the liquidation process. If a user's account becomes insolvent, the Controller Vault is allowed to seize the collateral from the enabled Collateral Vaults to repay the debt.

## What are Account Status Checks?

Account status checks are implemented by vaults to enforce account solvency. Vaults must expose an external `checkAccountStatus` function that will receive an account's address and this account's list of enabled collateral vaults. If the account has not borrowed anything from this vault then the function should return true. Otherwise, the vault should evaluate application-specific logic to determine whether or not the account is in an acceptable state.

## What are Vault Status Checks?

Some vaults may have constraints that should be enforced globally. For example, supply and/or borrow caps that restrict the maximum amount of assets that can be supplied or borrowed, as a risk minimisation. Vaults must expose an external `checkVaultStatus` function. The vault should evaluate application-specific logic to determine whether or not the vault is in an acceptable state.

## What are checks deferrals and how do they work?

Checks deferrals is the EVC feature which allows for the deferral of account and vault status checks until the end of the top-level checks-deferrable call. This means that checks for account solvency and vault constraints, which are usually performed immediately, can be postponed until the end of the call.
This feature is particularly useful in scenarios where multiple operations need to be performed in a specific sequence, and where the intermediate states of the account or vault might not meet the usual constraints. By deferring the checks, the EVC allows for a transient violation of account solvency or vault constraints, which can be useful in certain complex operations.
However, it's important to note that the checks are still performed at the end of the top-level call, ensuring that the final state of the account and vault still meet the necessary constraints. If the final state does not meet these constraints, the entire operation will fail.

## What is an Operator?

Operators are a more flexible and powerful version of approvals. These are EOAs or smart contracts that have been granted a permission to operate on behalf of the account. This includes interacting with vaults (i.e. withdrawing/borrowing funds), enabling vaults as collateral, etc. Because of this, it is recommended that only trusted and audited contracts, or EOAs held by a trusted individuals, be installed as operators. Operator concept can be used to build flexible products on top of the EVC, i.e. various automations, intents support, stop-loss/take-profit/trailing-stop/etc modifiers, position managers etc.

## What is the concept of sub-accounts in the EVC?

In the EVC, a sub-account is a concept that allows users to create multiple isolated positions within their single owner account. The sub-accounts belonging to the same owner share the first 19 bytes of their address and differ only in the last byte. This allows for the creation of isolated positions, where each sub-account can have its own set of enabled collateral vaults and a controller vault. 
Sub-accounts provide flexibility and control to the user. They can be used to manage different investment strategies or risk profiles within the same Ethereum address. Each sub-account can be independently liquidated without affecting the others, providing a level of risk isolation.

## What is the purpose of the `batch` function in the EVC?

The `batch` function in the EVC allows for the execution of a list of operations atomically, meaning that all operations either succeed together or fail together, ensuring consistency. The `batch` function defers account and vault status checks until the end of the top-level call. This allows for a transient violation of account solvency or vault constraints, which not only saves gas but can be useful in certain complex operations.

## How does the EVC handle gasless transactions?

The EVC handles gasless transactions, also known as meta-transactions, through a permit function.Permit function supports EIP-712 typed data messages that allow arbitrary calldata execution on the EVC on behalf of the signer (Account Owner or Account Operator) of the message. This means that a user can sign a message off-chain, which can then be sent to the EVC by another party who pays for the gas. 
This feature is particularly useful in scenarios where a user might not have enough ETH to pay for gas, or in applications that want to abstract away the concept of gas for a better user experience.

## How does the EVC support simulations?

The EVC supports simulations through a dedicated interface that allows for the execution of a batch of operations without actually modifying the state. This is particularly useful for inspecting the outcome of a batch before executing it, which can aid in decision-making and risk assessment.

## What is the purpose of the `impersonate` function in the EVC?

In the EVC, the `impersonate` function is a key mechanism that allows an enabled Controller Vault to execute arbitrary calldata on any of its enabled Collateral Vaults on behalf of a specified account.
This function is particularly useful during the liquidation process. When a user's account becomes insolvent, a liquidator initiates the liquidation process. As part of this process, the Controller Vault, using the `impersonate` function, seizes the collateral from the enabled Collateral Vaults to repay the debt.
In essence, the `impersonate` function provides a mechanism for enforcing the rules and conditions set by the Controller Vault, including the management of collateral during liquidations.

## How does the EVC interact with other smart contracts?

The EVC interacts with other smart contracts, including vaults, through several key functions: `callback`, `call`,`batch`, `impersonate`, `recoverRemainingETH`.

1. `callback`: The function allows the `msg.sender` to be called back by the EVC with specified calldata and the execution context set. The callback is executed with account and vault status checks deferred. This function is used when a vault is called directly and wants to imitate being called through the EVC.
1. `call`: The function allows an Account Owner or an Account Operator to execute arbitrary calldata on behalf of a specified account. This function is used to interact with other smart contracts while deferring account and vault status checks.
1. `batch`: The function allows for the execution of a list of operations atomically. This means that all operations either succeed together or fail together. This function is used when the EVC needs to interact with multiple smart contracts in a specific sequence.
1. `impersonate`: The function allows an enabled Controller Vault to execute arbitrary calldata on any of its enabled Collateral Vaults on behalf of a specified account. This function is particularly useful for liquidation flows, where the Controller Vault needs to interact with Collateral Vaults to seize collateral.
1. `recoverRemainingETH`: The function allows an Account Owner or an Account Operator to recover remaing ETH left in the EVC on behalf of a specified receiver account. If the receiver is a smart contract, its `fallback`/`receive` gets triggered.