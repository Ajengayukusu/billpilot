// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IPayable} from "@reactive/src/interfaces/IPayable.sol";
import {AbstractCallback} from "@reactive/src/base/AbstractCallback.sol";
import {BillVault} from "./BillVault.sol";

/// @title BillExecutor — BillPilot's callback receiver on Base Sepolia (chain 84532).
/// @notice Receives callbacks from BillPilotReactive (Lasna) via the official
///         Reactive callback proxy for Base Sepolia
///         (0x476F44b11F5C942c58f4c8E3d0300E5710743585) and executes the payout
///         batch on BillVault.
/// @dev Omni callback pattern — BOTH guards are required on the handler:
///      `onlyServiceProvider` (msg.sender must be the callback proxy) and
///      `onlyCallbackSender(reactive_)` (the first payload argument, which the
///      Reactive Network overwrites with the reactive contract's address, must
///      be our BillPilotReactive). The expected reactive address is immutable
///      (inherited `_CALLBACK_SENDER`), so deployment order matters:
///      reactive first, then this executor, then `BillPilotReactive.setRecipient`.
contract BillExecutor is AbstractCallback {
    event PayoutsExecuted(address indexed reactive, address indexed user, uint256 depositId);

    error ZeroAddress();

    /// @notice The vault this executor is authorised to pay out of.
    BillVault public immutable vault;

    /// @param callbackProxy_  Base Sepolia callback proxy (as an address; cast to IPayable).
    /// @param reactiveContract_ Address of BillPilotReactive on Lasna.
    /// @param vault_            Deployed BillVault address on Base Sepolia.
    constructor(address callbackProxy_, address reactiveContract_, address vault_)
        payable
        AbstractCallback(IPayable(payable(callbackProxy_)), reactiveContract_)
    {
        if (callbackProxy_ == address(0) || reactiveContract_ == address(0) || vault_ == address(0)) {
            revert ZeroAddress();
        }
        vault = BillVault(payable(vault_));
    }

    /// @notice Callback handler invoked by the proxy.
    /// @dev The first parameter is a placeholder in the payload sent by the
    ///      reactive contract (it passes `address(0)`); the Reactive Network
    ///      overwrites the first 160 bits of the payload with the reactive
    ///      contract's own address before delivery, which is what
    ///      `onlyCallbackSender` authenticates.
    function executePayouts(address reactive_, address user, uint256 depositId)
        external
        onlyServiceProvider
        onlyCallbackSender(reactive_)
    {
        vault.payAll(user, depositId);
        emit PayoutsExecuted(reactive_, user, depositId);
    }

    /// @notice Settle any outstanding debt to the callback proxy from this
    ///         contract's own balance (AbstractPayer plumbing). Permissionless
    ///         by design: it can only ever pay this contract's own debt to its
    ///         own service provider.
    function coverDebt() external {
        _coverDebt();
    }
}
