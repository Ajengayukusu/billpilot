# BillPilot — Set-It-and-Forget-It Bill Autopay

**Register your fixed payees once. Every time money lands in your vault, the chain pays your bills for you — automatically, in seconds, with a full on-chain receipt. No bots, no keepers, no server to keep alive.**

Built for the **Reactive Omni Buildathon** (DoraHacks), track **Set It and Forget It**.
Testnet only: **Base Sepolia** (origin + destination) and **Reactive Lasna** (reactive contract).

📺 **Live dashboard:** https://ajengayukusu.github.io/billpilot/ — payees, vault balance, and payment history read live from Base Sepolia, plus the two proven end-to-end loops with explorer links for every hop.

---

## The problem

Payday arrives, and then the manual ritual begins: rent for the boarding house (*kos*), the streaming subscription, the installment — each paid one by one, each easy to forget, each late payment punished with a fee. Existing "autopay" answers all need something babysat: a bank mandate you can't program, a keeper bot you must keep funded and online, or a cron server that is a single point of failure.

## The solution

BillPilot moves the ritual into the chain itself:

1. **Set it** — you register a fixed list of payees once (`setPayees`: wallet + fixed amount + label, up to 10).
2. **Fund it** — you `deposit()` ETH into BillVault whenever money comes in. That single call is the *only* thing you ever do again.
3. **Forget it** — a reactive contract on Reactive Lasna is subscribed to the vault's `DepositReceived` event. It reacts on-chain and requests a callback; BillExecutor on Base Sepolia runs the payout batch. Every payee whose fixed amount fits your remaining balance gets paid; a payee that doesn't fit is **skipped and recorded on-chain** (`PaymentSkipped`) instead of failing the whole batch. Leftovers stay in the vault, withdrawable any time.

## Architecture

```
        Base Sepolia (84532)                Reactive Lasna (5318007)              Base Sepolia (84532)
 ┌───────────────────────────┐      ┌───────────────────────────────┐      ┌────────────────────────────┐
 │         BillVault         │      │       BillPilotReactive       │      │        BillExecutor        │
 │                           │      │                               │      │                            │
 │  balances[user]           │      │  subscribed in constructor:   │      │  AbstractCallback          │
 │  payees[user] (fixed)     │      │  SYSTEM.subscribe(84532,      │      │  guards:                   │
 │  history[user]            │      │    vault, DepositReceived)    │      │   · onlyServiceProvider    │
 │                           │      │                               │      │     (msg.sender = proxy)   │
 │  deposit() ──emit──┐      │      │  react(log):                  │      │   · onlyCallbackSender     │
 └────────────────────┼──────┘      │   decode user/amount/id       │      │     (1st payload arg =     │
                      │             │   SYSTEM.requestCallback      │      │      reactive address)     │
        DepositReceived(user,       │     V_1_0(84532, executor,    │      │                            │
        amount, depositId) ─────────▶     gas 1,000,000,            │      │  executePayouts(reactive,  │
                      │  Reactive   │     payload = executePayouts) │      │    user, depositId)        │
                      │  Network    └──────────────┬────────────────┘      │        │                   │
                      │                            │  callback via         └────────┼───────────────────┘
                      │                            │  official proxy                │ vault.payAll(user, id)
                      │                            │  0x476F…3585                   ▼
                      │                            └──────────────▶  pays each payee · skips + records
                      │                                               underfunded ones · writes history
 └────────────────────┴───────────────────────────────────────────────────────────────────────────────┘
```

### How Reactive Omni is used here

- **Omni pattern, not legacy.** Lasna migrated to the Omni fork (Oct 2026): there is no RVM and no `vm` flag. `BillPilotReactive` extends `AbstractReactive` from `reactive-lib-omni` **v0.1.0**, talks to the system contract at `0x8888888888888888888888888888888888888888` (`SYSTEM`), and guards `react()` with `onlySystem`.
- **Subscription** happens in the reactive contract's constructor: `SYSTEM.subscribe(84532, <BillVault>, topic0(DepositReceived(address,uint256,uint256)), REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE)`.
- **Callback** uses the current API — `SYSTEM.requestCallbackV_1_0(...)` with a 1,000,000 gas limit — *not* the deprecated `Callback` event. The first payload argument is the reserved sender slot: the reactive contract passes `address(0)` and the network overwrites it with the reactive contract's address, which `BillExecutor` authenticates with `onlyCallbackSender`.
- **The reactive contract does real work**: it validates chain/contract/topic, decodes the depositor from `topic1` and `(amount, depositId)` from the log data, and routes the payout. Filtering is done by silently returning — never reverting (a revert in `react()` is still billed).
- **Debt discipline**: both the reactive contract (lREACT, Lasna) and the callback receiver (ETH, Base Sepolia) are pre-funded via `depositTo(...)`. Any outstanding debt silently stops delivery in the Reactive Network, so debt is checked after every loop — it was **0 on both sides after both live loops**.

## Contracts

| Contract | Chain | Address | Sourcify |
|---|---|---|---|
| BillVault | Base Sepolia (84532) | [`0x05Abd6e0a636B4D5ACB98540dc6b1f23D71F57b3`](https://sepolia.basescan.org/address/0x05Abd6e0a636B4D5ACB98540dc6b1f23D71F57b3) | [exact match](https://repo.sourcify.dev/contracts/full_match/84532/0x05Abd6e0a636B4D5ACB98540dc6b1f23D71F57b3/) |
| BillPilotReactive | Reactive Lasna (5318007) | [`0x35e3D4cdCd2EdFF55cDeb0c0710A8bF45e126871`](https://lasna.reactscan.net/address/0x35e3D4cdCd2EdFF55cDeb0c0710A8bF45e126871) | [exact match](https://repo.sourcify.dev/contracts/full_match/5318007/0x35e3D4cdCd2EdFF55cDeb0c0710A8bF45e126871/) |
| BillExecutor | Base Sepolia (84532) | [`0xFc2979342D96EeB950ba8246bCc8DF1868F3Df88`](https://sepolia.basescan.org/address/0xFc2979342D96EeB950ba8246bCc8DF1868F3Df88) | [exact match](https://repo.sourcify.dev/contracts/full_match/84532/0xFc2979342D96EeB950ba8246bCc8DF1868F3Df88/) |

- **BillVault** (no constructor args) — origin + funds. Per-user payee registry (`setPayees` / `getPayees` / `payeeCount`, cap 10), `deposit()` emitting `DepositReceived`, `withdraw()` for leftovers, executor-only `payAll()` with skip-and-continue semantics and a full `PaymentRecord` history (`getHistory` / `historyCount`). All timing uses timestamps, never block counts (Base Sepolia blocks are 200 ms).
- **BillPilotReactive** — constructor `(address vault, address executor)`; deployed with `executor = address(0)` and wired afterwards via owner-only `setRecipient()` (the executor needs the reactive address as its immutable callback sender, so this order is forced).
- **BillExecutor** — constructor `(address callbackProxy, address reactiveContract, address vault)` with the official Base Sepolia callback proxy `0x476F44b11F5C942c58f4c8E3d0300E5710743585`.

Deployment transactions: Vault [`0xa14fff…3887`](https://sepolia.basescan.org/tx/0xa14fff7e1d0aa01207dab289cf24272e1b82153cc04b90c134293e2401be3887) · Reactive [`0xec29b5…ad0dc`](https://lasna.reactscan.net/tx/0xec29b536dfad2ed4e081ad52f6298b0c35b4407dee11f02eb8387ba150aad0dc) · Executor [`0x1dcc99…1d2f7`](https://sepolia.basescan.org/tx/0x1dcc9965e777c5723da416c8e04e40f7cc028721ad6b4aeadd2b747ee721d2f7). Full deployment record: [`deployment.json`](deployment.json).

## Proof — two full loops, live on testnet

Both loops ran end-to-end with **no human or bot in the middle**: the only transactions sent by the project wallet were the deposits (and, for loop 2, a `setPayees` update first). The reactive and callback transactions were produced by the Reactive Network itself.

### Loop 1 — deposit 0.0015 ETH (payees: Kos 0.0006, Langganan 0.0004)

| Hop | Transaction | Evidence |
|---|---|---|
| Deposit (Base Sepolia) | [`0xf9000609…be4f`](https://sepolia.basescan.org/tx/0xf9000609969f46b30ed777a7d8480814a8f07b6251bd068c26237f5a4964be4f) | `DepositReceived(user, 0.0015 ETH, depositId 1)` |
| Reactive (Lasna) | [`0xf9057e08…c081`](https://lasna.reactscan.net/tx/0xf9057e084cace5328f8fde93251c2a14c6b82e197937cc1c0bcc6abf9f35c081) | `CallbackRequested(user, 0.0015 ETH, 1, executor)` |
| Callback (Base Sepolia) | [`0x58cd6b9a…2ae6`](https://sepolia.basescan.org/tx/0x58cd6b9a9720b89f62a2612da674056dd42fabdc74f75132f2e159ae34502ae6) | `PayoutsExecuted` + 2× `PaymentMade` |

**End-to-end latency: 1 s** (block timestamps). Both payees paid in full; vault leftover 0.0005 ETH; debt 0 / 0 after.

### Loop 2 — deposit 0.001 ETH (payees re-set: Kos 0.0003, Langganan 0.0002)

| Hop | Transaction | Evidence |
|---|---|---|
| Deposit (Base Sepolia) | [`0xf9813aaf…b166`](https://sepolia.basescan.org/tx/0xf9813aafc4174daa545828300c44f3a5a3897853392c54916db295989861b166) | `DepositReceived(user, 0.001 ETH, depositId 2)` |
| Reactive (Lasna) | [`0xaa81edf6…9647`](https://lasna.reactscan.net/tx/0xaa81edf6d42c3d77e3e4a178d14f7ba1b068ac0352ac9394e8af8575df809647) | `CallbackRequested(user, 0.001 ETH, 2, executor)` |
| Callback (Base Sepolia) | [`0x37fac4ed…56d6`](https://sepolia.basescan.org/tx/0x37fac4ed222ab967c70a2818ddd2a1878b3a3ce5bc9e55c6eda8ab04e9a356d6) | `PayoutsExecuted` + 2× `PaymentMade` |

**End-to-end latency: 3 s** (block timestamps). Both payees paid in full (cumulative: Kos 0.0009 ETH, Langganan 0.0006 ETH); vault leftover 0.001 ETH; on-chain history holds 4 records, all `paid: true`; debt 0 / 0 after.

## Reproduce it

### Build & test (local)

```bash
forge build
forge test        # 36 tests, incl. a local full-loop simulation run twice
```

### Deploy (testnet)

You need a wallet funded on **both** networks (see faucets below), then deploy **in this order**:

1. **BillVault** → Base Sepolia. No constructor args.
2. **BillPilotReactive** → Lasna, constructor `(vault, address(0))`, with some lREACT as constructor value (it pays its own subscription/billing float). ⚠️ Lasna's base fee is **100 gwei** — deploy with a legacy transaction at that price or it fails:
   `forge create --legacy --gas-price 100gwei …` (RPC: `https://lasna-rpc.rnk.dev/`)
3. **BillExecutor** → Base Sepolia, constructor `(0x476F44b11F5C942c58f4c8E3d0300E5710743585, <reactive>, <vault>)`.
4. **Wire it**: `BillVault.setExecutor(executor)` and `BillPilotReactive.setRecipient(executor)`.
5. **Fund the debt floats** (skip this and callbacks silently stop):
   - Executor: call `depositTo(executor)` on the Base Sepolia callback proxy with a small ETH amount.
   - Reactive: call `depositTo(reactive)` on the Lasna system contract (`0x8888…8888`) with a small lREACT amount. Never send lREACT directly to the system contract — always use `depositTo(address)`.
6. **Use it**: `setPayees([...])`, then `deposit()` and watch the callback land seconds later. Check `debt()` on both contracts after each loop; top up with `coverDebt()` / `depositTo` when needed.

### Faucets

- **Base Sepolia ETH**: any standard Base Sepolia faucet (this project claimed via Zalalena; Google Cloud Web3 faucet covers Sepolia-family chains).
- **lREACT (Lasna)**: there is no web drip — send Base Sepolia ETH to the faucet contract `0x2afaFD298b23b62760711756088F75B7409f5967` via `request(address)`; you receive **100 lREACT per 1 ETH** on Lasna (this deployment used 0.0015 ETH → 0.15 lREACT).

### Verify

All three contracts are verified on Sourcify with **exact match** (links in the contract table). To re-verify: `forge verify-contract --verifier sourcify --chain-id <84532|5318007> <address> src/<Contract>.sol:<Contract>` with the exact constructor args from the table above.

## Repository layout

```
src/        BillVault.sol · BillPilotReactive.sol · BillExecutor.sol
test/       36 Foundry tests (vault, executor, reactive, full-loop simulation, mocks)
docs/       Static dashboard (GitHub Pages) — ethers v6 via importmap + ES modules only
deployment.json   Machine-readable deployment + loop proof record
```

## Tech stack

Solidity `^0.8.29` · Foundry 1.9.0 · `reactive-lib-omni` v0.1.0 (`Reactive-Network/reactive-lib-omni` @ `3ade0dc`) · ethers v6 (dashboard) · Sourcify verification · GitHub Pages.

## License

MIT — see [LICENSE](LICENSE).
