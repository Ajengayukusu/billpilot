// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";

/// @notice Test double for the Reactive system contract (0x8888…8888) and, in a
///         pinch, for a callback proxy (both are `IPayable`-shaped). Tests etch
///         this contract's code at the real system address and then read the
///         recorded calls back through that same address — the deployed mock
///         instance's own storage is NOT shared with the etched copy.
contract MockSystemContract {
    // subscribe recording
    uint256 public subscribeCalls;
    uint256 public unsubscribeCalls;
    uint256 public lastChainId;
    address public lastContract;
    uint256 public lastTopic0;
    uint256 public lastTopic1;
    uint256 public lastTopic2;
    uint256 public lastTopic3;

    // callback recording
    uint256 public callbackRequests;
    uint256 public lastCallbackChainId;
    address public lastRecipient;
    uint64 public lastGasLimit;
    bytes public lastPayload;

    // IPayable debt knob
    uint256 public debtAmount;

    function setDebt(uint256 amount) external {
        debtAmount = amount;
    }

    function debt(address) external view returns (uint256) {
        return debtAmount;
    }

    receive() external payable {}

    function subscribe(
        uint256 chainId_,
        address contract_,
        uint256 topic0_,
        uint256 topic1_,
        uint256 topic2_,
        uint256 topic3_
    ) external {
        subscribeCalls++;
        lastChainId = chainId_;
        lastContract = contract_;
        lastTopic0 = topic0_;
        lastTopic1 = topic1_;
        lastTopic2 = topic2_;
        lastTopic3 = topic3_;
    }

    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external {
        unsubscribeCalls++;
    }

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory config_) external {
        callbackRequests++;
        lastCallbackChainId = config_.chainId;
        lastRecipient = config_.recipient;
        lastGasLimit = config_.gasLimit;
        lastPayload = config_.payload;
    }

    function requestCallback(ISystemContract.CallbackVersion, bytes memory) external {
        callbackRequests++;
    }
}
