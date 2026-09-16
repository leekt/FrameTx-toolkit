# vFrame

**A Solidity EntryPoint for testing frame-style transactions on a stock EVM.**
Deploy it like any other contract and submit operations through an ordinary transaction.
It needs no FrameTx EIPs, new opcodes, custom compiler, account delegation, or node patches.
The standalone project compiles with stock **solc 0.8.30**, targeting **Osaka**.
Its reentrancy lock and active sender use transient storage, with explicit cleanup between
operations in the same transaction.

## Run the tests

From the repository root, using stock Foundry:

```bash
# If this project's test dependencies have not been restored:
(cd vframe && forge soldeer install)

forge test --root vframe -vv
```

The standalone `foundry.toml` uses only this project's sources and tests. The contracts
have no external dependencies. Tests and the demo use forge-std, pinned in this project's
own `soldeer.lock`; nothing is imported from `contracts/` or the toolchain forks.

## What it does

| Frame mode | Ordinary EVM operation | Caller seen by the target |
|---|---|---|
| `VERIFY` (`1`) | `STATICCALL` to `validateFrame(context, frames, authorization)` | vFrame |
| `DEFAULT` (`0`) | vFrame routes a `CALL` through its `defaultCaller` contract | The DEFAULT caller |
| `SENDER` (`2`) | vFrame calls the account's `executeFrame`, which calls the target | The sender account |

Each vFrame deployment creates its own [`VFrameDefaultCaller`](src/VFrameDefaultCaller.sol),
available through `entryPoint.defaultCaller()`. Only that EntryPoint can invoke the router.
Targets receive the original frame data and zero value; their return or revert data is
forwarded with the same size bound as other frames. The router shares the frame's gas budget
and participates in ordinary and atomic rollback. Its address is a shared caller identity,
not proof of approval by a particular sender.

Validators return a magic value and an approval scope: payment (`1`), execution (`2`),
both (`3`), or no approval (`0`) for an independent check. They receive the verified
EntryPoint's transaction hash, sender, maximum cost, capped gas price, frame index,
allowed scope, and complete signed frame list. Signed policy data is at
`frames[context.frameIndex].data`. A validator can use
ECDSA, a custom signature scheme, an allowlist, or other ordinary contract logic.

Only the sender account can approve execution. Only one payment approval and one execution
approval are accepted. Payment requires the sender's prior or combined execution approval,
so a third-party payer cannot consume another account's nonce. A successful payment approval
reserves the maximum gas cost from the payer's deposit and increments every selected nonce
key exactly once. Settlement refunds unused funds and credits the relayer for gas charged.
Execution-frame failure still consumes gas and the nonce. A failed `VERIFY`, missing
approval, or invalid operation reverts the whole `handle` call, including its deposit
and nonce changes.

Bit `4` in an execution frame's flags groups that frame with its successor. A group's
terminator has the bit cleared. A nested call supplies the rollback boundary: failure
undoes all of the group's writes, transfers and logs, skips the rest of that group, then
continues with later frames. Approval frames cannot be part of an atomic group.

`handle` returns one `Result` per frame and emits `FrameResult` events. Each result has
`status` (`0` failed, `1` returned successfully, `2` skipped), `rolledBack`, and bounded
return data. Earlier successful calls in a failed group remain status `1` with
`rolledBack = true`; their return data is omitted. The failed call contains a
`BatchReverted(failedIndex, originalReason)` wrapper. Ordinary return/revert data is capped
at 2,048 bytes; the batch error adds its ABI header.

## Build an operation

The ABI is defined in [`IVFrame.sol`](src/IVFrame.sol):

```text
Transaction {
  sender, nonceKeys[], nonce, validUntil,
  overheadGasLimit, maxFeePerGas, maxPriorityFeePerGas,
  frames[], authorizations[]
}
Frame { mode, flags, target, gasLimit, value, data }
```

1. Deploy [`vFrame`](src/vFrame.sol) and a
   [`VFrameAccount`](src/VFrameAccount.sol) with that EntryPoint and an owner. The DEFAULT
   caller is deployed automatically by vFrame's constructor.
2. Fund the account for any transferred value. Separately call
   `entryPoint.depositTo{value: amount}(payer)` for relayer payments. Its deposit must cover
   `entryPoint.getGasQuote(transaction).maxCost` before payment approval.
3. Use `nonceKeys = [0]` for the default sequence and read
   `entryPoint.nonces(sender, 0)`. Nonzero sorted, distinct keys provide independent
   sequences. Multiple selected keys must all have the supplied `nonce`.
4. Add a `VERIFY` frame targeting the account with flags `3`, then `SENDER` frames for
   the calls. A zero target resolves to the sender account. Set `validUntil = 0` for no
   expiry; otherwise the timestamp is inclusive. Set each frame's `gasLimit`, an additional
   `overheadGasLimit` for EntryPoint work, and the two per-gas fee caps.
5. Sign `entryPoint.getTransactionHash(transaction)`. This is an EIP-712 digest with
   domain name `vFrame`, version `1`, the chain ID, and the EntryPoint's address.
   The owner example accepts canonical 65-byte `r || s || v`, with `v` equal to 27 or 28.
   Use typed-data signing or sign the digest directly; do not add a personal-sign prefix.
6. Place the signature in `authorizations[verifyFrameIndex]`. The array must have one
   entry per frame, with empty bytes for non-VERIFY frames. Witness bytes are excluded
   from the hash; all call data, targets, values, flags, gas budgets, nonces, expiry and
   the gas budgets and fee caps are signed.
7. A relayer submits `entryPoint.handle(transaction)`. An `eth_call` of the same input
   previews returned frame results without committing state. Set its `from` to the
   intended relayer and supply `gasPrice` for realistic payment estimates. A mined
   transaction exposes the results and gas settlement through events.

The [test suite](test/VFrame.t.sol) contains complete builders and signatures.
It also covers a `DEFAULT` factory call deploying a CREATE2 account before its validation.

### Sponsorship

Deploy [`VFrameSponsor`](src/VFrameSponsor.sol) and fund its deposit. Give the
sender's VERIFY frame execution-only flags (`2`), then add a sponsor VERIFY frame with
payment-only flags (`1`). The account owner and sponsor owner each sign the same operation
hash, placing signatures in their respective authorization entries. The sender needs no
deposit. The sponsor reserves the signed maximum cost, pays for gas charged, and receives
the unused reservation back. The relayer can withdraw its credited balance with `withdrawTo`.

### Gas payment

There is no caller-supplied flat `fee`. vFrame derives the reservation from signed budgets:

```text
gasLimit = overheadGasLimit + sum(frame.gasLimit)
maxCost = gasLimit * maxFeePerGas
gasPrice = min(tx.gasprice, maxFeePerGas, block.basefee + maxPriorityFeePerGas)
gasUsed = measured handle gas + SETTLEMENT_GAS
chargedFee = gasUsed * gasPrice
payerRefund = maxCost - chargedFee
```

`getGasQuote(transaction)` returns `gasLimit`, `maxCost`, and the price for the current
call context. Both price caps and every gas budget are included in the EIP-712 hash.
Priority fee cannot exceed max fee, max fee must cover the base fee, and the aggregate
budget cannot exceed 16,777,216 gas. Payment approval requires the **full reservation**,
even if the expected final charge is smaller. The signed overhead budget must be at least
the 40,000-gas `SETTLEMENT_GAS` allowance; it is a limit, not an automatic charge.

The meter starts at the beginning of the `handle` body and ends after frame-result events,
just before deposit settlement. It includes validation, dispatch, returned-data handling,
and gas spent on reverted calls and atomic groups. Skipped frames have no call-gas charge.
The final accounting, event, return encoding and lock cleanup use the fixed 40,000-gas
allowance because those operations occur after the measurement. If gas charged exceeds
the aggregate signed budget, the entire operation reverts.

`TransactionHandled` reports `gasUsed`, `gasPrice`, `chargedFee`, and `refund` alongside
the operation hash, sender, payer and relayer. Deposit accounting conserves funds:
the reservation is split between the payer's refund and the relayer's credit.

This follows the reserve/charge/refund pattern in
[EIP-8141](https://eips.ethereum.org/EIPS/eip-8141#gas-accounting), using ordinary EVM gas.
It is **an application-level reimbursement**, not the outer transaction's exact network fee.
Outer intrinsic/calldata charges, network storage refunds, calldata floors, and L2 data fees
are not measured or reconciled. The settlement allowance is an estimate. A relayer pays any
remaining outer cost, including a gas price above the signed caps. An `eth_call` with zero
gas price previews a zero charge.

### Account execution guard

Custom accounts must check **both** `msg.sender == address(entryPoint)` and
`entryPoint.isExecuting(address(this))` in `executeFrame`. These checks require an active,
approved SENDER dispatch. DEFAULT calls arrive from the separate router.
The supplied account implements both checks and permits owner rotation only through a
SENDER self-call. Execution targets must not treat generic calls from the DEFAULT caller as
proof that any particular user approved them.

## Deploy and run the demo

The [demo script](script/VFrameDemo.s.sol) deploys vFrame and its DEFAULT caller, an account
and a counter, funds the account's deposit with **0.01 ETH**, then relays an owner-signed
operation with one SENDER increment and one DEFAULT increment. It checks both caller identities.
Use a local node or a testnet, with a funded relayer key and a separate owner key:

```bash
export VFRAME_OWNER_KEY=<owner-test-private-key>
export VFRAME_RELAYER_KEY=<funded-relayer-test-private-key>

forge script --root vframe \
  vframe/script/VFrameDemo.s.sol:VFrameDemo \
  --rpc-url "$RPC_URL" --broadcast --slow
```

The owner needs no ETH. The relayer pays ordinary network gas and receives the calculated
gas reimbursement as deposit credit. Omitting `--broadcast` simulates
the script. The script prints the four deployed addresses and checks execution and
accounting. Its outer call supplies an explicit gas limit to cover the signed frame
budgets: a multiplier applied only to simulated gas consumption may be insufficient.

## Testing boundaries

- This is a contract testing harness with its own ABI and signature domain. It is neither
  a native type-`0x06` decoder nor an ERC-4337 `UserOperation` endpoint. Existing native
  opcode-based accounts need ordinary Solidity validation and execution methods.
- The sender is a participating smart account. vFrame cannot impersonate an unmodified
  EOA. `tx.origin` remains the outer relayer, and DEFAULT targets see the dedicated
  `defaultCaller` address, not the native `0xaa` address.
- Every nonce, including key zero, lives in vFrame storage. None changes an EOA's nonce.
  No account-trie, state-gas, blob, recent-root, code-reuse or native signature machinery
  is involved.
- External contracts' transient storage follows ordinary EIP-1153 lifetime: it survives
  between vFrame calls within the same outer transaction. vFrame can clear its own context
  but cannot clear another contract's transient slots. Native EIP-8141 clears transient
  storage between frames; that isolation cannot be reproduced by this contract router.
- `gasLimit` is a normal call budget. DEFAULT budgets include the router, SENDER budgets
  include the account adapter, and validation includes ordinary signature verification.
  Estimates and measured gas are
  not native FrameTx gas. The relayer must supply enough outer gas for all calls and
  bookkeeping. Payment uses the metered gas and capped price described above.
- Approvals are returned only from VERIFY frames. A late validation failure reverts the
  entire operation; this does not emulate EIP-7906 POST_TX fee-preserving rollback.
- Per-frame events are application receipts. A valid operation can have failed execution
  frames while the outer transaction succeeds. Atomic state rollback is real EVM rollback;
  no host fixtures or frame-specific cheatcodes implement it.

These choices use ordinary [Solidity static calls and view functions](https://docs.soliditylang.org/en/v0.8.30/contracts.html#view-functions),
[transient storage](https://docs.soliditylang.org/en/v0.8.30/contracts.html#transient-storage),
and [nested-call rollback](https://docs.soliditylang.org/en/v0.8.30/control-structures.html#error-handling-assert-require-revert-and-exceptions).
