// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {AbstractPayer} from "@reactive/src/base/AbstractPayer.sol";
import {AbstractCallback} from "@reactive/src/base/AbstractCallback.sol";
import {BillVault} from "../src/BillVault.sol";
import {BillExecutor} from "../src/BillExecutor.sol";
import {MockSystemContract} from "./mocks/MockSystemContract.sol";

contract BillExecutorTest is Test {
    BillVault internal vault;
    BillExecutor internal exec;
    address internal proxy = makeAddr("callbackProxy");
    address internal reactive = makeAddr("billPilotReactive");
    address internal user = makeAddr("user");
    address internal payeeA = makeAddr("payeeA");
    address internal payeeB = makeAddr("payeeB");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        vault = new BillVault();
        exec = new BillExecutor(proxy, reactive, address(vault));
        vault.setExecutor(address(exec));

        BillVault.Payee[] memory p = new BillVault.Payee[](2);
        p[0] = BillVault.Payee({wallet: payeeA, amount: 0.3 ether, label: "Rent"});
        p[1] = BillVault.Payee({wallet: payeeB, amount: 0.2 ether, label: "Streaming"});
        vm.prank(user);
        vault.setPayees(p);
        vm.deal(user, 10 ether);
    }

    function _deposit() internal returns (uint256 id) {
        vm.prank(user);
        id = vault.deposit{value: 1 ether}();
    }

    function test_ExecutePayouts_ViaProxyPaysPayees() public {
        uint256 id = _deposit();

        vm.expectEmit(true, true, false, true, address(exec));
        emit BillExecutor.PayoutsExecuted(reactive, user, id);
        vm.prank(proxy);
        exec.executePayouts(reactive, user, id);

        assertEq(payeeA.balance, 0.3 ether);
        assertEq(payeeB.balance, 0.2 ether);
        assertEq(vault.balances(user), 0.5 ether);
        assertEq(vault.historyCount(user), 2);
    }

    function test_ExecutePayouts_DirectCallReverts() public {
        uint256 id = _deposit();
        // Not the proxy -> onlyServiceProvider must reject.
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, stranger, proxy));
        vm.prank(stranger);
        exec.executePayouts(reactive, user, id);
    }

    function test_ExecutePayouts_WrongReactiveSenderReverts() public {
        uint256 id = _deposit();
        // From the proxy, but the injected sender is not our reactive contract.
        vm.expectRevert(
            abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, stranger, reactive)
        );
        vm.prank(proxy);
        exec.executePayouts(stranger, user, id);
    }

    function test_Constructor_StoresVaultAndSender() public view {
        assertEq(address(exec.vault()), address(vault));
        assertEq(exec._CALLBACK_SENDER(), reactive);
        assertEq(address(exec._SERVICE_PROVIDER()), proxy);
    }

    function test_CoverDebt_PaysProxyFromBalance() public {
        // Etch a debt-aware mock at the proxy address: debt is read from the
        // etched copy's storage, so set it through that address.
        MockSystemContract mock = new MockSystemContract();
        vm.etch(proxy, address(mock).code);
        MockSystemContract etched = MockSystemContract(payable(proxy));
        etched.setDebt(0.05 ether);

        vm.deal(address(exec), 0.2 ether);
        uint256 proxyBefore = proxy.balance;
        exec.coverDebt();

        assertEq(proxy.balance, proxyBefore + 0.05 ether);
        assertEq(address(exec).balance, 0.15 ether);
    }

    function test_Receive_AcceptsFunding() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok,) = address(exec).call{value: 0.4 ether}("");
        assertTrue(ok);
        assertEq(address(exec).balance, 0.4 ether);
    }
}
