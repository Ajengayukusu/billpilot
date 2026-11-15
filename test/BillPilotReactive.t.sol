// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {AbstractPayer} from "@reactive/src/base/AbstractPayer.sol";
import {BillVault} from "../src/BillVault.sol";
import {BillExecutor} from "../src/BillExecutor.sol";
import {BillPilotReactive} from "../src/BillPilotReactive.sol";
import {MockSystemContract} from "./mocks/MockSystemContract.sol";

contract BillPilotReactiveTest is Test {
    address internal constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    uint256 internal constant REACTIVE_IGNORE = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;
    address internal constant BASE_PROXY = 0x476F44b11F5C942c58f4c8E3d0300E5710743585;

    BillVault internal vault;
    BillPilotReactive internal reactive;
    MockSystemContract internal sys; // the etched copy lives at SYSTEM_ADDR

    address internal user = makeAddr("user");
    address internal executorAddr = makeAddr("executor");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        // Etch the mock system contract at the real SYSTEM address BEFORE
        // deploying the reactive contract (its constructor subscribes).
        MockSystemContract mock = new MockSystemContract();
        vm.etch(SYSTEM_ADDR, address(mock).code);
        sys = MockSystemContract(payable(SYSTEM_ADDR));

        vault = new BillVault();
        reactive = new BillPilotReactive(address(vault), executorAddr);
    }

    function _depositLog(address who, uint256 amount, uint256 depositId)
        internal
        view
        returns (IReactive.LogRecord memory log)
    {
        log = IReactive.LogRecord({
            chainId: 84532,
            contractAddress: address(vault),
            topic0: uint256(keccak256("DepositReceived(address,uint256,uint256)")),
            topic1: uint256(uint160(who)),
            topic2: 0,
            topic3: 0,
            data: abi.encode(amount, depositId),
            blockNumber: 12345,
            opCode: 2,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
    }

    // ----------------------------------------------------------- constructor

    function test_Constructor_SubscribesToVaultDeposits() public view {
        assertEq(sys.subscribeCalls(), 1);
        assertEq(sys.lastChainId(), 84532);
        assertEq(sys.lastContract(), address(vault));
        assertEq(sys.lastTopic0(), uint256(keccak256("DepositReceived(address,uint256,uint256)")));
        assertEq(sys.lastTopic1(), REACTIVE_IGNORE);
        assertEq(sys.lastTopic2(), REACTIVE_IGNORE);
        assertEq(sys.lastTopic3(), REACTIVE_IGNORE);
        assertEq(reactive.vault(), address(vault));
        assertEq(reactive.executor(), executorAddr);
        assertEq(reactive.owner(), address(this));
    }

    function test_TopicConstant_MatchesVaultEvent() public {
        // The hardcoded topic in the reactive contract must be the topic the
        // vault actually emits — guard against signature drift.
        vm.recordLogs();
        vm.deal(user, 1 ether);
        vm.prank(user);
        vault.deposit{value: 0.1 ether}();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertGt(logs.length, 0);
        assertEq(uint256(logs[0].topics[0]), reactive.DEPOSIT_TOPIC0());
    }

    // ----------------------------------------------------------------- react

    function test_React_RequestsCallback() public {
        IReactive.LogRecord memory log = _depositLog(user, 1 ether, 7);

        vm.expectEmit(true, false, false, true, address(reactive));
        emit BillPilotReactive.CallbackRequested(user, 1 ether, 7, executorAddr);
        vm.prank(SYSTEM_ADDR);
        reactive.react(log);

        assertEq(sys.callbackRequests(), 1);
        assertEq(sys.lastCallbackChainId(), 84532);
        assertEq(sys.lastRecipient(), executorAddr);
        assertEq(sys.lastGasLimit(), 1_000_000);
        bytes memory expected =
            abi.encodeWithSignature("executePayouts(address,address,uint256)", address(0), user, 7);
        assertEq(sys.lastPayload(), expected);
    }

    function test_React_OnlySystem() public {
        IReactive.LogRecord memory log = _depositLog(user, 1 ether, 1);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, stranger, SYSTEM_ADDR));
        vm.prank(stranger);
        reactive.react(log);
        assertEq(sys.callbackRequests(), 0);
    }

    function test_React_IgnoresWrongTopicSilently() public {
        IReactive.LogRecord memory log = _depositLog(user, 1 ether, 1);
        log.topic0 = uint256(keccak256("SomeOtherEvent(address,uint256,uint256)"));
        vm.prank(SYSTEM_ADDR);
        reactive.react(log); // must NOT revert
        assertEq(sys.callbackRequests(), 0);
    }

    function test_React_IgnoresWrongChainSilently() public {
        IReactive.LogRecord memory log = _depositLog(user, 1 ether, 1);
        log.chainId = 1;
        vm.prank(SYSTEM_ADDR);
        reactive.react(log);
        assertEq(sys.callbackRequests(), 0);
    }

    function test_React_IgnoresWrongContractSilently() public {
        IReactive.LogRecord memory log = _depositLog(user, 1 ether, 1);
        log.contractAddress = stranger;
        vm.prank(SYSTEM_ADDR);
        reactive.react(log);
        assertEq(sys.callbackRequests(), 0);
    }

    function test_React_IgnoresShortDataSilently() public {
        IReactive.LogRecord memory log = _depositLog(user, 1 ether, 1);
        log.data = abi.encode(uint256(1)); // only one word — decode would revert
        vm.prank(SYSTEM_ADDR);
        reactive.react(log);
        assertEq(sys.callbackRequests(), 0);
    }

    function test_React_NoRecipientYet_SkipsSilently() public {
        BillPilotReactive pending = new BillPilotReactive(address(vault), address(0));
        IReactive.LogRecord memory log = _depositLog(user, 1 ether, 1);
        vm.prank(SYSTEM_ADDR);
        pending.react(log);
        assertEq(sys.callbackRequests(), 0);
    }

    // ------------------------------------------------------------ setRecipient

    function test_SetRecipient_OwnerOnly_AndTakesEffect() public {
        BillPilotReactive pending = new BillPilotReactive(address(vault), address(0));

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(BillPilotReactive.NotOwner.selector, stranger));
        pending.setRecipient(executorAddr);

        pending.setRecipient(executorAddr);
        assertEq(pending.executor(), executorAddr);

        IReactive.LogRecord memory log = _depositLog(user, 2 ether, 9);
        vm.prank(SYSTEM_ADDR);
        pending.react(log);
        assertEq(sys.callbackRequests(), 1);
        assertEq(sys.lastRecipient(), executorAddr);
    }

    // -------------------------------------------------------------- coverDebt

    function test_CoverDebt_PaysSystemFromBalance() public {
        sys.setDebt(0.03 ether);
        vm.deal(address(reactive), 0.1 ether);
        uint256 sysBefore = SYSTEM_ADDR.balance;
        reactive.coverDebt();
        assertEq(SYSTEM_ADDR.balance, sysBefore + 0.03 ether);
        assertEq(address(reactive).balance, 0.07 ether);
    }
}

/// @notice End-to-end local simulation of the full BillPilot loop:
///         vault deposit -> (recorded log) -> system calls react() ->
///         callback payload captured -> sender injected -> proxy delivers ->
///         executor pays the payees out of the vault.
contract FullLoopTest is Test {
    address internal constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    address internal constant BASE_PROXY = 0x476F44b11F5C942c58f4c8E3d0300E5710743585;

    BillVault internal vault;
    BillPilotReactive internal reactive;
    BillExecutor internal exec;
    MockSystemContract internal sys;

    address internal user = makeAddr("user");
    address internal payeeA = makeAddr("payeeA");
    address internal payeeB = makeAddr("payeeB");

    function setUp() public {
        MockSystemContract mock = new MockSystemContract();
        vm.etch(SYSTEM_ADDR, address(mock).code);
        sys = MockSystemContract(payable(SYSTEM_ADDR));

        vault = new BillVault();
        // Deployment order per the Omni docs: reactive first (recipient unset),
        // executor second (needs the reactive address), then wire the recipient.
        reactive = new BillPilotReactive(address(vault), address(0));
        exec = new BillExecutor(BASE_PROXY, address(reactive), address(vault));
        reactive.setRecipient(address(exec));
        vault.setExecutor(address(exec));

        BillVault.Payee[] memory p = new BillVault.Payee[](2);
        p[0] = BillVault.Payee({wallet: payeeA, amount: 0.3 ether, label: "Rent"});
        p[1] = BillVault.Payee({wallet: payeeB, amount: 0.2 ether, label: "Streaming"});
        vm.prank(user);
        vault.setPayees(p);
        vm.deal(user, 10 ether);
    }

    /// @dev The network overwrites the first payload argument (bytes 16..35 of
    ///      the calldata: 4 selector + 12 padding) with the reactive address.
    function _injectSender(bytes memory payload, address sender) internal pure returns (bytes memory) {
        bytes20 b = bytes20(sender);
        for (uint256 i = 0; i < 20; ++i) {
            payload[16 + i] = b[i];
        }
        return payload;
    }

    function _runLoop(uint256 depositAmount) internal returns (uint256 depositId) {
        // 1) User deposits on the origin (Base Sepolia side).
        vm.recordLogs();
        vm.prank(user);
        depositId = vault.deposit{value: depositAmount}();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(uint256(logs[0].topics[0]), reactive.DEPOSIT_TOPIC0());

        // 2) The system contract delivers the log to the reactive contract.
        IReactive.LogRecord memory log = IReactive.LogRecord({
            chainId: 84532,
            contractAddress: address(vault),
            topic0: uint256(logs[0].topics[0]),
            topic1: uint256(logs[0].topics[1]),
            topic2: 0,
            topic3: 0,
            data: logs[0].data,
            blockNumber: block.number,
            opCode: 2,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
        vm.prank(SYSTEM_ADDR);
        reactive.react(log);
        assertEq(sys.lastRecipient(), address(exec));

        // 3) The callback proxy delivers the payload, sender injected.
        bytes memory payload = _injectSender(sys.lastPayload(), address(reactive));
        vm.prank(BASE_PROXY);
        (bool ok, bytes memory err) = address(exec).call(payload);
        if (!ok) revert(string(err));
    }

    function test_FullLoop_TwoDepositsDifferentAmounts() public {
        _runLoop(1 ether);
        assertEq(payeeA.balance, 0.3 ether);
        assertEq(payeeB.balance, 0.2 ether);
        assertEq(vault.balances(user), 0.5 ether);
        assertEq(vault.historyCount(user), 2);

        _runLoop(0.4 ether);
        // Balance before loop 2 payouts: 0.5 + 0.4 = 0.9; pays 0.3 + 0.2 again.
        assertEq(payeeA.balance, 0.6 ether);
        assertEq(payeeB.balance, 0.4 ether);
        assertEq(vault.balances(user), 0.4 ether);
        assertEq(vault.historyCount(user), 4);
        assertEq(sys.callbackRequests(), 2);
    }
}
