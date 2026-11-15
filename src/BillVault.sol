// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title BillVault — BillPilot's origin + funds contract on Base Sepolia (chain 84532).
/// @notice Users register a fixed list of payees once, then simply deposit ETH.
///         Every `deposit()` emits `DepositReceived`, which BillPilotReactive (on Lasna)
///         is subscribed to. The reactive contract requests a callback, and the
///         authorised executor (BillExecutor) calls `payAll()` to settle the payees.
/// @dev The vault itself contains no Reactive code — it is a plain origin contract.
///      All autopay logic that needs the user's balance lives here, where the
///      balance actually lives. `payAll()` never reverts a whole batch: a payee
///      whose fixed amount exceeds the remaining balance is skipped, recorded
///      on-chain, and the loop continues with the next payee.
contract BillVault {
    // ------------------------------------------------------------------ types

    struct Payee {
        address wallet;
        uint256 amount;
        string label;
    }

    struct PaymentRecord {
        address user;
        address payee;
        uint256 amount;
        uint256 timestamp;
        uint256 depositId;
        bool paid;
    }

    // ----------------------------------------------------------------- errors

    error NotOwner(address caller);
    error NotExecutor(address caller);
    error ZeroDeposit();
    error ZeroAddress();
    error ZeroAmount();
    error InvalidPayee(uint256 index);
    error TooManyPayees(uint256 count, uint256 max);
    error InsufficientBalance(uint256 requested, uint256 available);
    error TransferFailed(address to, uint256 amount);
    error Reentrant();

    // ----------------------------------------------------------------- events

    /// @notice The event BillPilotReactive subscribes to. `user` is indexed
    ///         (arrives as topic1 on Lasna); `amount` + `depositId` are
    ///         ABI-encoded in the log data.
    event DepositReceived(address indexed user, uint256 amount, uint256 depositId);
    event PayeesUpdated(address indexed user, uint256 count);
    event PaymentMade(address indexed user, address indexed payee, uint256 amount, uint256 depositId);
    event PaymentSkipped(address indexed user, address indexed payee, uint256 amount, uint256 depositId);
    event PaymentFailed(address indexed user, address indexed payee, uint256 amount, uint256 depositId);
    event Withdrawn(address indexed user, uint256 amount);
    event ExecutorSet(address indexed executor);

    // ------------------------------------------------------------------ state

    /// @notice Hard cap on payees per user — keeps a single callback's gas bounded.
    uint256 public constant MAX_PAYEES = 10;

    address public immutable owner;
    address public executor;

    /// @notice Internal (accounted) ETH balance per user.
    mapping(address => uint256) public balances;

    /// @notice Global deposit counter; the first deposit gets id 1.
    uint256 public nextDepositId = 1;
    uint256 public totalDeposits;

    mapping(address => Payee[]) private _payees;
    mapping(address => PaymentRecord[]) private _history;

    uint256 private _lock = 1;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        _;
    }

    modifier onlyExecutor() {
        if (executor == address(0) || msg.sender != executor) revert NotExecutor(msg.sender);
        _;
    }

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrant();
        _lock = 2;
        _;
        _lock = 1;
    }

    constructor() {
        owner = msg.sender;
    }

    // -------------------------------------------------------------- admin

    /// @notice Authorise the BillExecutor contract to run payouts. Owner only.
    function setExecutor(address executor_) external onlyOwner {
        if (executor_ == address(0)) revert ZeroAddress();
        executor = executor_;
        emit ExecutorSet(executor_);
    }

    // -------------------------------------------------------------- payees

    /// @notice Replace the caller's payee list in one call.
    function setPayees(Payee[] calldata newPayees) external {
        if (newPayees.length > MAX_PAYEES) revert TooManyPayees(newPayees.length, MAX_PAYEES);
        for (uint256 i = 0; i < newPayees.length; ++i) {
            if (newPayees[i].wallet == address(0) || newPayees[i].amount == 0) {
                revert InvalidPayee(i);
            }
        }
        delete _payees[msg.sender];
        for (uint256 i = 0; i < newPayees.length; ++i) {
            _payees[msg.sender].push(newPayees[i]);
        }
        emit PayeesUpdated(msg.sender, newPayees.length);
    }

    function getPayees(address user) external view returns (Payee[] memory) {
        return _payees[user];
    }

    function payeeCount(address user) external view returns (uint256) {
        return _payees[user].length;
    }

    // -------------------------------------------------------------- funds

    /// @notice Canonical deposit path — credits the caller and emits the event
    ///         that triggers the reactive autopay loop.
    /// @return depositId The global id assigned to this deposit.
    function deposit() external payable returns (uint256 depositId) {
        if (msg.value == 0) revert ZeroDeposit();
        depositId = nextDepositId++;
        totalDeposits++;
        balances[msg.sender] += msg.value;
        emit DepositReceived(msg.sender, msg.value, depositId);
    }

    /// @notice Plain transfers are accepted and credited to the sender's internal
    ///         balance (withdrawable via `withdraw()`), but deliberately do NOT
    ///         emit `DepositReceived` — only `deposit()` triggers autopay.
    receive() external payable {
        balances[msg.sender] += msg.value;
    }

    /// @notice Withdraw any leftover balance at any time.
    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 bal = balances[msg.sender];
        if (amount > bal) revert InsufficientBalance(amount, bal);
        balances[msg.sender] = bal - amount;
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        if (!ok) revert TransferFailed(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function balanceOf(address user) external view returns (uint256) {
        return balances[user];
    }

    // -------------------------------------------------------------- payouts

    /// @notice Pay every payee of `user` their fixed amount, in list order.
    ///         Called by the authorised executor in response to a deposit.
    ///         A payee is paid only if the user's remaining balance covers the
    ///         fixed amount; otherwise that payee is skipped (recorded +
    ///         `PaymentSkipped`) and the loop continues — the batch as a whole
    ///         never reverts because of one underfunded payee.
    function payAll(address user, uint256 depositId) external nonReentrant onlyExecutor {
        Payee[] storage list = _payees[user];
        uint256 len = list.length;
        for (uint256 i = 0; i < len; ++i) {
            address payeeWallet = list[i].wallet;
            uint256 amount = list[i].amount;

            if (balances[user] < amount || address(this).balance < amount) {
                _history[user].push(
                    PaymentRecord({
                        user: user,
                        payee: payeeWallet,
                        amount: amount,
                        timestamp: block.timestamp,
                        depositId: depositId,
                        paid: false
                    })
                );
                emit PaymentSkipped(user, payeeWallet, amount, depositId);
                continue;
            }

            // Effects before interaction (checks-effects-interactions).
            balances[user] -= amount;
            (bool ok,) = payable(payeeWallet).call{value: amount}("");
            if (!ok) {
                // Transfer failed: restore the balance and record the miss
                // instead of reverting the whole batch.
                balances[user] += amount;
                _history[user].push(
                    PaymentRecord({
                        user: user,
                        payee: payeeWallet,
                        amount: amount,
                        timestamp: block.timestamp,
                        depositId: depositId,
                        paid: false
                    })
                );
                emit PaymentFailed(user, payeeWallet, amount, depositId);
                continue;
            }

            _history[user].push(
                PaymentRecord({
                    user: user,
                    payee: payeeWallet,
                    amount: amount,
                    timestamp: block.timestamp,
                    depositId: depositId,
                    paid: true
                })
            );
            emit PaymentMade(user, payeeWallet, amount, depositId);
        }
    }

    // -------------------------------------------------------------- history

    function getHistory(address user) external view returns (PaymentRecord[] memory) {
        return _history[user];
    }

    function historyCount(address user) external view returns (uint256) {
        return _history[user].length;
    }
}
