// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {BillVault} from "../src/BillVault.sol";

contract BillVaultTest is Test {
    BillVault internal vault;
    address internal owner = address(this);
    address internal user = makeAddr("user");
    address internal payeeA = makeAddr("payeeA");
    address internal payeeB = makeAddr("payeeB");
    address internal payeeC = makeAddr("payeeC");
    address internal executor = makeAddr("executor");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        vault = new BillVault();
        vault.setExecutor(executor);
        vm.deal(user, 100 ether);
    }

    function _payeesABC() internal view returns (BillVault.Payee[] memory p) {
        p = new BillVault.Payee[](3);
        p[0] = BillVault.Payee({wallet: payeeA, amount: 0.3 ether, label: "Rent"});
        p[1] = BillVault.Payee({wallet: payeeB, amount: 0.2 ether, label: "Streaming"});
        p[2] = BillVault.Payee({wallet: payeeC, amount: 0.4 ether, label: "Loan"});
    }

    // ------------------------------------------------------------ setPayees

    function test_SetPayees_StoresList() public {
        vm.prank(user);
        vault.setPayees(_payeesABC());

        assertEq(vault.payeeCount(user), 3);
        BillVault.Payee[] memory got = vault.getPayees(user);
        assertEq(got[0].wallet, payeeA);
        assertEq(got[0].amount, 0.3 ether);
        assertEq(got[0].label, "Rent");
        assertEq(got[2].wallet, payeeC);
    }

    function test_SetPayees_ReplacesList() public {
        vm.prank(user);
        vault.setPayees(_payeesABC());

        BillVault.Payee[] memory one = new BillVault.Payee[](1);
        one[0] = BillVault.Payee({wallet: payeeB, amount: 1 ether, label: "Only"});
        vm.prank(user);
        vault.setPayees(one);

        assertEq(vault.payeeCount(user), 1);
        assertEq(vault.getPayees(user)[0].wallet, payeeB);
    }

    function test_SetPayees_RejectsZeroWallet() public {
        BillVault.Payee[] memory bad = new BillVault.Payee[](1);
        bad[0] = BillVault.Payee({wallet: address(0), amount: 1 ether, label: "Bad"});
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BillVault.InvalidPayee.selector, 0));
        vault.setPayees(bad);
    }

    function test_SetPayees_RejectsZeroAmount() public {
        BillVault.Payee[] memory bad = new BillVault.Payee[](1);
        bad[0] = BillVault.Payee({wallet: payeeA, amount: 0, label: "Bad"});
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BillVault.InvalidPayee.selector, 0));
        vault.setPayees(bad);
    }

    function test_SetPayees_RejectsTooMany() public {
        BillVault.Payee[] memory many = new BillVault.Payee[](11);
        for (uint256 i = 0; i < 11; ++i) {
            many[i] = BillVault.Payee({wallet: payeeA, amount: 1, label: "x"});
        }
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BillVault.TooManyPayees.selector, 11, 10));
        vault.setPayees(many);
    }

    // -------------------------------------------------------------- deposit

    function test_Deposit_CreditsBalanceAndEmits() public {
        vm.expectEmit(true, false, false, true, address(vault));
        emit BillVault.DepositReceived(user, 1 ether, 1);
        vm.prank(user);
        uint256 id = vault.deposit{value: 1 ether}();

        assertEq(id, 1);
        assertEq(vault.balances(user), 1 ether);
        assertEq(vault.balanceOf(user), 1 ether);
        assertEq(address(vault).balance, 1 ether);
    }

    function test_Deposit_IdsIncrement() public {
        vm.startPrank(user);
        uint256 id1 = vault.deposit{value: 0.5 ether}();
        uint256 id2 = vault.deposit{value: 0.25 ether}();
        vm.stopPrank();
        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(vault.totalDeposits(), 2);
        assertEq(vault.balances(user), 0.75 ether);
    }

    function test_Deposit_ZeroReverts() public {
        vm.prank(user);
        vm.expectRevert(BillVault.ZeroDeposit.selector);
        vault.deposit{value: 0}();
    }

    function test_Receive_CreditsWithoutTriggering() public {
        vm.prank(user);
        (bool ok,) = address(vault).call{value: 0.7 ether}("");
        assertTrue(ok);
        assertEq(vault.balances(user), 0.7 ether);
        assertEq(vault.totalDeposits(), 0); // no DepositReceived path taken
    }

    // ------------------------------------------------------------- withdraw

    function test_Withdraw_ReturnsLeftover() public {
        vm.prank(user);
        vault.deposit{value: 2 ether}();

        uint256 before = user.balance;
        vm.prank(user);
        vault.withdraw(0.5 ether);

        assertEq(vault.balances(user), 1.5 ether);
        assertEq(user.balance, before + 0.5 ether);
    }

    function test_Withdraw_MoreThanBalanceReverts() public {
        vm.prank(user);
        vault.deposit{value: 1 ether}();
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BillVault.InsufficientBalance.selector, 2 ether, 1 ether));
        vault.withdraw(2 ether);
    }

    // --------------------------------------------------------------- payAll

    function test_PayAll_PaysEveryoneWhenSufficient() public {
        vm.prank(user);
        vault.setPayees(_payeesABC());
        vm.prank(user);
        uint256 id = vault.deposit{value: 1 ether}();

        vm.prank(executor);
        vault.payAll(user, id);

        assertEq(payeeA.balance, 0.3 ether);
        assertEq(payeeB.balance, 0.2 ether);
        assertEq(payeeC.balance, 0.4 ether);
        assertEq(vault.balances(user), 0.1 ether); // leftover stays withdrawable

        assertEq(vault.historyCount(user), 3);
        BillVault.PaymentRecord[] memory h = vault.getHistory(user);
        assertTrue(h[0].paid && h[1].paid && h[2].paid);
        assertEq(h[0].payee, payeeA);
        assertEq(h[0].depositId, id);
        assertEq(h[0].timestamp, block.timestamp);
    }

    function test_PayAll_SkipsInsufficientPayeeAndContinues() public {
        // Payee B costs more than the deposit; A and C must still be paid,
        // in order, and B must be recorded as skipped — never a batch revert.
        BillVault.Payee[] memory p = new BillVault.Payee[](3);
        p[0] = BillVault.Payee({wallet: payeeA, amount: 0.3 ether, label: "Rent"});
        p[1] = BillVault.Payee({wallet: payeeB, amount: 5 ether, label: "TooBig"});
        p[2] = BillVault.Payee({wallet: payeeC, amount: 0.4 ether, label: "Loan"});
        vm.prank(user);
        vault.setPayees(p);
        vm.prank(user);
        uint256 id = vault.deposit{value: 1 ether}();

        vm.expectEmit(true, true, false, true, address(vault));
        emit BillVault.PaymentSkipped(user, payeeB, 5 ether, id);
        vm.prank(executor);
        vault.payAll(user, id);

        assertEq(payeeA.balance, 0.3 ether);
        assertEq(payeeB.balance, 0);
        assertEq(payeeC.balance, 0.4 ether);
        assertEq(vault.balances(user), 0.3 ether);

        BillVault.PaymentRecord[] memory h = vault.getHistory(user);
        assertEq(h.length, 3);
        assertTrue(h[0].paid);
        assertFalse(h[1].paid); // the skipped one
        assertEq(h[1].payee, payeeB);
        assertTrue(h[2].paid);
    }

    function test_PayAll_RunningBalance_SkipsLaterPayeeWhenDrained() public {
        // Two payees, deposit covers only the first: second is skipped.
        BillVault.Payee[] memory p = new BillVault.Payee[](2);
        p[0] = BillVault.Payee({wallet: payeeA, amount: 0.6 ether, label: "First"});
        p[1] = BillVault.Payee({wallet: payeeB, amount: 0.6 ether, label: "Second"});
        vm.prank(user);
        vault.setPayees(p);
        vm.prank(user);
        uint256 id = vault.deposit{value: 1 ether}();

        vm.prank(executor);
        vault.payAll(user, id);

        assertEq(payeeA.balance, 0.6 ether);
        assertEq(payeeB.balance, 0);
        assertEq(vault.balances(user), 0.4 ether);
    }

    function test_PayAll_OnlyExecutor() public {
        vm.prank(user);
        vault.setPayees(_payeesABC());
        vm.prank(user);
        uint256 id = vault.deposit{value: 1 ether}();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(BillVault.NotExecutor.selector, stranger));
        vault.payAll(user, id);
    }

    function test_PayAll_NoPayeesIsNoOp() public {
        vm.prank(user);
        uint256 id = vault.deposit{value: 1 ether}();
        vm.prank(executor);
        vault.payAll(user, id);
        assertEq(vault.balances(user), 1 ether);
        assertEq(vault.historyCount(user), 0);
    }

    // ---------------------------------------------------------- setExecutor

    function test_SetExecutor_OnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(BillVault.NotOwner.selector, stranger));
        vault.setExecutor(stranger);
    }

    function test_OwnerIsDeployer() public view {
        assertEq(vault.owner(), owner);
        assertEq(vault.executor(), executor);
    }
}
