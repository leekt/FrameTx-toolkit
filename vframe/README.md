# vFrame

**A Solidity EntryPoint for testing frame-style transactions on a stock EVM.**
Deploy it like any other contract and submit operations through an ordinary transaction.
It needs no FrameTx EIPs, new opcodes, custom compiler, account delegation, or node patches.
The standalone project compiles with stock **solc 0.8.30**, targeting **Osaka**.
Its lock, active sender, and transaction/frame/signature context use transient storage.
Context readers are disabled between operations in the same outer transaction.

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
| `VERIFY` (`1`) | Gas-capped `CALL` with the complete `frame.data` calldata | vFrame |
| `DEFAULT` (`0`) | vFrame routes a `CALL` through its `defaultCaller` contract | The DEFAULT caller |
| `SENDER` (`2`) | vFrame calls the account's `executeFrame`, which calls the target | The sender account |

Each vFrame deployment creates its own [`VFrameDefaultCaller`](src/VFrameDefaultCaller.sol),
available through `entryPoint.defaultCaller()`. Only that EntryPoint can invoke the router.
Targets receive the original frame data and zero value; their return or revert data is
forwarded with the same size bound as other frames. The router shares the frame's gas budget
and participates in ordinary and atomic rollback. Its address is a shared caller identity,
not proof of approval by a particular sender.

Validators return a magic value and an approval scope: payment (`1`), execution (`2`),
both (`3`), or no approval (`0`) for an independent check. VERIFY uses raw
`target.call(frame.data)`. The examples expose `validateFrame(bytes calldata data)`, so
encode the selector and arguments into `frame.data`; custom validators may use any selector.
Validators decode their own parameters and read the transaction hash, sender, maximum cost, current
frame, allowed scope, and other frames through the context readers. A validator can use
ECDSA, a custom signature scheme, an allowlist, or other ordinary contract logic.
The transaction has an explicit signature list, independent of frame count. Its metadata
and witness bytes are available through the context readers below. **vFrame verifies every
SECP256K1 and P256 entry before executing any frame**, even if no validator uses it. Accounts
check the verified signer, scheme and message against their authorization policy. ARBITRARY
witnesses remain the consuming validator’s responsibility.

The web demo's pay-after-swap sequence uses two VERIFY frames:
`VERIFY execution → SENDER calls → VERIFY payment`. The first uses execution-only flags
(`2`), so it does not require a gas deposit. The last uses payment-only flags (`1`) and can
fund the gas reservation from ETH received by the earlier calls. Both call `validateFrame`.

As an alternative, execution approval can also happen in DEFAULT mode: call the sender account's
`approveExecution(signatureIndex)` with flags `2`. The account checks its owner's verified
signature and calls `vFrame.approveExecution()`. That callback only accepts the sender while
it is the current DEFAULT frame's target and execution approval is explicitly allowed.
Its transient approval rolls back if the frame reverts. This permits
`DEFAULT authorize → SENDER calls → VERIFY pay`, with one VERIFY at the end.
Unapproved SENDER frames remain invalid. This private-inclusion ordering is outside native
EIP-8141 public-mempool policy. This harness's payment approvals still use VERIFY frames.

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
  frames[], signatures[]
}
Frame { mode, flags, target, gasLimit, value, data }
Signature { scheme, signer, message, signature }
```

1. Deploy [`vFrame`](src/vFrame.sol) and [`VFrameAccountFactory`](src/VFrameAccountFactory.sol).
   `factory.getAddress(owner, salt)` predicts an account; `createAccount(owner, salt)`
   deploys it idempotently. A DEFAULT frame can deploy it before its VERIFY frame in the
   same operation. The owner is bound into the creation code, so another caller cannot
   take over the predicted account. The DEFAULT caller is deployed by vFrame’s constructor.
2. Fund the account’s predicted address with ETH for execution and gas. On a payment
   validation, the supplied account or sponsor calls `depositTo` for only the missing
   part of `getGasQuote(transaction).maxCost`. An existing deposit may cover some or all
   of that reservation. Gas must be funded before a swap; later swap proceeds cannot
   pay the earlier validation. The outer relayer still needs network gas.
3. Use `nonceKeys = [0]` for the default sequence and read
   `entryPoint.nonces(sender, 0)`. Nonzero sorted, distinct keys provide independent
   sequences. Multiple selected keys must all have the supplied `nonce`.
4. Add a `VERIFY` frame targeting the account with flags `3`, then `SENDER` frames for
   the calls. A zero target resolves to the sender account. Set `validUntil = 0` for no
   expiry; otherwise the timestamp is inclusive. Set each frame's `gasLimit`, an additional
   `overheadGasLimit` for EntryPoint work, and the two price-range fields.
5. Populate `signatures[]` with each entry's scheme, declared signer, and message.
   The owner example uses scheme `1` (SECP256K1), its owner's address, and zero message
   to authorize the transaction hash. Set the VERIFY frame’s data to
   `abi.encodeCall(IVFrameValidator.validateFrame, (abi.encode(signatureIndex)))`; an empty
   **bytes argument** selects index zero. Then sign `entryPoint.getTransactionHash(transaction)`.
   This is an EIP-712 digest with domain name `vFrame`, version `2`, the chain ID, and
   the EntryPoint's address. The owner example accepts canonical 65-byte `v || r || s`,
   with `v` equal to 0 or 1 and low `s`.
   P256 uses scheme `2`, signer `address(uint160(uint256(keccak256(abi.encode(qx, qy)))))`,
   and `r || s || qx || qy` (128 bytes). Both schemes require low `s`. P256 uses the
   [EIP-7951](https://eips.ethereum.org/EIPS/eip-7951) precompile at `0x100`, available on
   Osaka; an absent precompile fails closed. This verifies a raw digest, not a WebAuthn
   assertion wrapper. Use typed-data signing or sign the digest directly; do not add
   a personal-sign prefix.
6. Place the witness in `signatures[signatureIndex].signature`. All signature metadata
   and the ordered list are signed. Only witnesses with zero `message` are elided from
   the hash. A nonzero message denotes an explicit digest and commits its witness bytes
   too. All frame data, targets, values, flags, gas budgets, nonce keys, expiry and fee
   caps are signed. Finalize every entry's metadata before collecting signatures.
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
hash, placing signatures in their selected list entries. Each VERIFY frame's signed data
selects its entry. Both example validators require a verified SECP256K1/P256 owner
and zero message (the entire operation). They also authenticate the EntryPoint and
current VERIFY mode before approval or prefunding. The sender needs no deposit. The sponsor reserves the signed maximum cost, pays for gas charged, and receives
the unused reservation back. The relayer can withdraw its credited balance with `withdrawTo`.

### Reading the active context

The readers are built into `vFrame.sol` and declared in `IVFrameContext`. Before executing
frames, vFrame snapshots transaction, frame, and signature fields with `TSTORE`. It updates
the current frame index before each dispatch. Readers use `TLOAD`, including when called
from a validator or deeper inside a DEFAULT/SENDER call.

```solidity
// Inside validateFrame(bytes calldata data):
uint256 index = entryPoint.txParam(0x0a);
address sender = address(uint160(entryPoint.txParam(0x02)));
uint256 mode = entryPoint.frameParam(index, 0x02);
uint256 allowedScope = entryPoint.frameParam(index, 0x06);
bytes32 signingHash = bytes32(entryPoint.txParam(0x08));

uint256 signatureIndex = data.length == 0 ? 0 : abi.decode(data, (uint256));
uint256 scheme = entryPoint.sigParam(signatureIndex, 0x01);
bytes memory witness = entryPoint.signatureData(signatureIndex);
// For SECP256K1/P256, require the verified signer to be authorized and message == 0.
// For ARBITRARY, verify the witness yourself against signingHash and your policy.
```

The numeric selectors follow [EIP-8141](https://eips.ethereum.org/EIPS/eip-8141#introspection)
and [EIP-8250](https://eips.ethereum.org/EIPS/eip-8250#transaction-introspection):

| Reader | Available fields |
|---|---|
| `txParam(param)` | Virtual type `0x06`, sequence, sender, fee caps, maximum deposit reservation, vFrame signing hash, frame count, current frame index, signature count, nonce-key count/hash/first key |
| `frameParam(index, param)` | Resolved target, call gas budget, mode, flags, data length, completed status, allowed scope, atomic flag, value |
| `sigParam(index, param)` | Verified/resolved signer (`0`), scheme (`1`), message (`2`), ARBITRARY witness length (`3`) |
| `frameData(index)` | Complete signed frame data |
| `signatureData(index)` | Complete witness bytes, for any scheme |

The type, hash and reservation describe the virtual operation, not the outer transaction.
Blob fee/count selectors return zero. Native state gas and account-trie nonce selectors
(`TXPARAM 0x0c/0x0d`, `FRAMEPARAM 0x09–0x0b`) revert as unsupported. Status is available
only for earlier frames; current/future status, invalid selectors and out-of-range indices
revert. Completed statuses survive a failed atomic group, including skipped frames.

Signature schemes use native numbers (`0` ARBITRARY, `1` SECP256K1, `2` P256).
SECP256K1/P256 signer metadata is verified before all frames. A zero declared signer
resolves to the sender. ARBITRARY entries must declare a zero signer and have no exposed
signer; the length selector is available only for ARBITRARY entries. Unknown schemes are
rejected. Unlike native `SIGDATACOPY`, `signatureData` exposes every scheme’s raw bytes.
The example account and sponsor support both verified schemes and reject explicit-message
signatures for authorization, since those do not necessarily commit to this operation.

All readers revert outside frame execution. Success disables the context; a reverted
operation rolls back its transient writes. Counts and lengths prevent shorter operations
later in the same outer transaction from exposing stale entries or bytes. Transient context
setup costs gas and is included in metered reimbursement.

**ABI migration:** `authorizations[]` is replaced by `signatures[]`, the validator callback
is raw calldata (the example uses `validateFrame(bytes)`), and the EIP-712 domain version is now `2`. `ValidationContext`
and the callback's frame-array argument are removed. Rebuild and re-sign old operations.
The native toolkit's transaction format is unchanged.

### Gas payment

There is no caller-supplied flat `fee`. vFrame derives the reservation from signed budgets:

```text
gasLimit = overheadGasLimit + sum(frame.gasLimit)
lowerPrice = maxFeePerGas
upperPrice = maxFeePerGas + maxPriorityFeePerGas
maxCost = gasLimit * upperPrice
gasPrice = min(max(block.basefee, lowerPrice), upperPrice)
gasUsed = measured handle gas + SETTLEMENT_GAS
chargedFee = gasUsed * gasPrice
payerRefund = maxCost - chargedFee
```

`getGasQuote(transaction)` returns `gasLimit`, `maxCost`, and the price for the current
call context. Both price caps and every gas budget are included in the EIP-712 hash.
In this harness, `maxFeePerGas` is the reimbursement floor and `maxPriorityFeePerGas` is
the allowance above it; these are deliberately different from native EIP-1559 semantics.
The network base fee is clamped to that signed range. `tx.gasprice` has no effect on the
virtual charge. Both bounds may be below the network base fee, including zero: the relayer
accepts the difference when submitting the ordinary outer transaction. Addition and
reservation multiplication overflow are rejected. The aggregate budget cannot exceed
16,777,216 gas. Payment approval requires the **full reservation at the upper price**,
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
remaining outer cost. An `eth_call` uses the same virtual price calculation as a mined call,
but some RPCs set the simulated base fee to zero when outer fee fields are omitted or zero.
For a representative quote, provide network fee fields, an explicit outer gas limit and a
funded relayer address, and pin the call to the block whose base fee you are comparing.

### Account execution guard

Custom accounts must check **both** `msg.sender == address(entryPoint)` and
`entryPoint.isExecuting(address(this))` in `executeFrame`. These checks require an active,
approved SENDER dispatch. DEFAULT calls arrive from the separate router.
The supplied account also checks current SENDER mode and permits owner rotation only through a
SENDER self-call. Execution targets must not treat generic calls from the DEFAULT caller as
proof that any particular user approved them.

## Deploy and run the demo

The [demo script](script/VFrameDemo.s.sol) deploys vFrame and its DEFAULT caller, an account
and a counter, funds the account with **0.01 ETH**, then relays an owner-signed
operation with one SENDER increment and one DEFAULT increment. Validation prefunds the deposit.
It checks both caller identities.
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
  include the account adapter, and validation includes account policy and prefunding calls. Signature verification is
  EntryPoint overhead before the frames.
  Estimates and measured gas are
  not native FrameTx gas. The relayer must supply enough outer gas for all calls and
  bookkeeping. Payment uses the metered gas and capped price described above.
- VERIFY intentionally uses mutable CALL to support ERC-4337-style prefunding. Native
  EIP-8141 VERIFY uses static execution with its protocol approval exception. Custom
  validators must authenticate the EntryPoint and frame mode before changing state.
- Approvals are returned only from VERIFY frames. A late validation failure reverts the
  entire operation; this does not emulate EIP-7906 POST_TX fee-preserving rollback.
- Per-frame events are application receipts. A valid operation can have failed execution
  frames while the outer transaction succeeds. Atomic state rollback is real EVM rollback;
  no host fixtures or frame-specific cheatcodes implement it.

These choices use ordinary Solidity calls,
[transient storage](https://docs.soliditylang.org/en/v0.8.30/contracts.html#transient-storage),
and [nested-call rollback](https://docs.soliditylang.org/en/v0.8.30/control-structures.html#error-handling-assert-require-revert-and-exceptions).

## Sepolia deployment and web playground

Use the existing Foundry keystore account `ZERODEV_DEPLOYER`, funded with Sepolia ETH.
From the repository root:

```bash
export SEPOLIA_RPC_URL=https://ethereum-sepolia-rpc.publicnode.com
forge script --root vframe vframe/script/DeployVFrame.s.sol:DeployVFrame \
  --rpc-url "$SEPOLIA_RPC_URL" --account ZERODEV_DEPLOYER --broadcast --slow
```

Both contracts deploy through the standard CREATE2 proxy at
`0x4e59b44847b379578588920cA78FbF26c0B4956C`, with salts `keccak256("vFrame")` and
`keccak256("VFrameAccountFactory")`. Their addresses do not depend on the deploying wallet
or its nonce. The DEFAULT caller is also deterministic because vFrame creates it in its
constructor. Contract code, constructor arguments, salts and compiler settings determine
the addresses; changing any of them can change an address. The compiler settings are pinned
in `foundry.toml`. Run the script with `--sig "predict()"` to preview both addresses.

Rerunning the deployment reuses contracts already present at the predicted addresses.
The same command writes the calculated addresses to `web/.env.local` before deployment,
preserving other settings. A dry run also writes them: remove `--broadcast` to configure
the demo before sending transactions. The addresses are predictions until deployment
succeeds. The deployment RPC URL is not copied into frontend configuration. To resume an
interrupted broadcast, append `--resume` to the command using the same wallet and RPC.

```bash
cd web
npm ci
npm run dev
```

See [the web README](../web/README.md) for the swap flow, remote access and validation.
Each user’s account is created on demand by their first DEFAULT frame.
