// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {AbstractReactive} from "@reactive/src/base/AbstractReactive.sol";

/// @title BillPilotReactive — BillPilot's reactive contract on Lasna (chain 5318007).
/// @notice Subscribes to `DepositReceived` from BillVault on Base Sepolia. On each
///         deposit it requests a callback (Omni `requestCallbackV_1_0`) to
///         BillExecutor on Base Sepolia, which pays the depositor's fixed payees.
/// @dev Omni pattern only: single contract on the Reactive Network, no RVM, no
///      `vm` flag. Filtering in `react()` is done by silently returning — never
///      by reverting (a revert is still billed and logged as
///      `ReactiveContractReverted`). The first payload argument is reserved:
///      the network overwrites it with this contract's address, so we pass
///      `address(0)` as the placeholder.
contract BillPilotReactive is AbstractReactive {
    // -------------------------------------------------------------- constants

    uint256 public constant ORIGIN_CHAIN_ID = 84532; // Base Sepolia
    uint256 public constant DESTINATION_CHAIN_ID = 84532; // Base Sepolia
    uint64 public constant CALLBACK_GAS_LIMIT = 1_000_000;

    /// @notice topic0 of `DepositReceived(address,uint256,uint256)`.
    uint256 public constant DEPOSIT_TOPIC0 =
        uint256(keccak256("DepositReceived(address,uint256,uint256)"));

    // ----------------------------------------------------------------- errors

    error NotOwner(address caller);
    error ZeroAddress();

    // ----------------------------------------------------------------- events

    event RecipientSet(address indexed executor);
    event CallbackRequested(address indexed user, uint256 amount, uint256 depositId, address indexed recipient);

    // ------------------------------------------------------------------ state

    address public immutable owner;
    /// @notice Origin contract on Base Sepolia whose deposits we watch.
    address public immutable vault;
    /// @notice Callback recipient on Base Sepolia (BillExecutor). Settable by
    ///         the owner because of the deployment order: this contract is
    ///         deployed first, the executor second (it needs this address as
    ///         its immutable callback sender), then the recipient is wired here.
    address public executor;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        _;
    }

    /// @param vaultOnBase_    BillVault address on Base Sepolia.
    /// @param executorOnBase_ BillExecutor address on Base Sepolia; may be
    ///                         `address(0)` at deploy time and set later via
    ///                         `setRecipient`.
    constructor(address vaultOnBase_, address executorOnBase_) payable {
        if (vaultOnBase_ == address(0)) revert ZeroAddress();
        owner = msg.sender;
        vault = vaultOnBase_;
        // forge-lint: disable-next-line(missing-zero-check)
        executor = executorOnBase_; // may intentionally be address(0) until setRecipient()

        SYSTEM.subscribe(
            ORIGIN_CHAIN_ID,
            vaultOnBase_,
            DEPOSIT_TOPIC0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
    }

    /// @notice Set/update the callback recipient (BillExecutor). Owner only.
    function setRecipient(address executor_) external onlyOwner {
        if (executor_ == address(0)) revert ZeroAddress();
        executor = executor_;
        emit RecipientSet(executor_);
    }

    /// @inheritdoc IReactive
    /// @dev Signature uses `calldata` to match `IReactive` in reactive-lib-omni
    ///      v0.1.0 (the docs' `memory` example does not match the pinned lib).
    function react(LogRecord calldata log_) external onlySystem {
        // Silent filtering — return, never revert, on anything that is not
        // exactly the deposit event we subscribed to.
        if (log_.chainId != ORIGIN_CHAIN_ID) return;
        if (log_.contractAddress != vault) return;
        if (log_.topic0 != DEPOSIT_TOPIC0) return;
        if (log_.data.length < 64) return;
        address recipient = executor;
        if (recipient == address(0)) return;

        // `user` is the indexed event parameter -> topic1 (an address is
        // stored zero-extended in a topic, so the truncation cast is exact).
        // `amount` + `depositId` are the non-indexed parameters -> log data.
        // forge-lint: disable-next-line(unsafe-typecast)
        address user = address(uint160(log_.topic1));
        (uint256 amount, uint256 depositId) = abi.decode(log_.data, (uint256, uint256));

        bytes memory payload = abi.encodeWithSignature(
            "executePayouts(address,address,uint256)",
            address(0), // placeholder — overwritten with this contract's address
            user,
            depositId
        );

        // Emitted before the external call; if the call reverts, the whole
        // transaction (and this event) is rolled back, so the log stays truthful.
        emit CallbackRequested(user, amount, depositId, recipient);

        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: DESTINATION_CHAIN_ID,
                recipient: recipient,
                gasLimit: CALLBACK_GAS_LIMIT,
                payload: payload
            })
        );
    }

    /// @notice Settle any outstanding debt to the system contract from this
    ///         contract's own balance (AbstractPayer plumbing). Permissionless
    ///         by design: it can only ever pay this contract's own debt to the
    ///         system contract.
    function coverDebt() external {
        _coverDebt();
    }
}
