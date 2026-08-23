# Migrating accounts to frame transactions

EIP-8141 is still a Draft with an open
[`execution-specs` implementation tracker](https://github.com/ethereum/execution-specs/issues/2829)
in the [Bogota milestone](https://github.com/ethereum/execution-specs/milestone/29). Treat this
as a migration design and test plan, not a mainnet cutover runbook. The toolkit is a prototype:
it has no public-pool propagation policy or production audit, and its local ML-DSA scheme is
not part of upstream EIP-8141.

The safest migration keeps the old authorization path usable until the new path has survived
realistic canaries and a rollback window.

| Starting account | Practical path | Address continuity |
|---|---|---|
| Upgradeable ERC-4337 account | Upgrade to a deliberately dual-mode implementation | Same address |
| Non-upgradeable ERC-4337 account | Deploy a new Frame-capable account and migrate assets and permissions | New address |
| Plain EOA, secp256k1 is acceptable | Use EIP-8141 default code | Same address; no state migration |
| Plain EOA needing wallet logic | Optionally install audited dual-mode code with EIP-7702 | Same address; ECDSA remains the protocol root |
| Account that must retire ECDSA completely | Deploy a code account with the desired validation policy | Normally a new address |

Primary specifications: [ERC-4337](https://eips.ethereum.org/EIPS/eip-4337),
[EIP-7702](https://eips.ethereum.org/EIPS/eip-7702), and
[EIP-8141](https://eips.ethereum.org/EIPS/eip-8141).

## Executable migration examples

The repository now contains two production-shaped adapters and tests against real migration
machinery rather than storage-only mocks:

- [`KernelV33FrameAccount.sol`](../contracts/src/accounts/KernelV33FrameAccount.sol) and
  [`KernelV33Migration.t.sol`](../contracts/test/KernelV33Migration.t.sol) exercise a deployed
  Kernel v3.3 proxy through a compact compatibility shim. The fixture imports the actual
  ZeroDev factory, Kernel implementation, and ECDSA root validator from
  [`contracts/vendor/kernel-v3.3`](../contracts/vendor/kernel-v3.3), pinned to official commit
  [`cd697c7e21715d015e0643af22310a99aa17433b`](https://github.com/zerodevapp/kernel/tree/cd697c7e21715d015e0643af22310a99aa17433b).
- [`EOA7702FrameAccount.sol`](../contracts/src/accounts/EOA7702FrameAccount.sol) and
  [`EOA7702Migration.t.sol`](../contracts/test/EOA7702Migration.t.sol) exercise same-address
  installation and clearing with Foundry's EIP-7702 delegation processing.

Both adapters' test fixtures inherit the shared
[`AccountTestSuite`](../contracts/test/AccountTestSuite.sol), which covers self-validation and
payment (`BOTH`), validation under external sponsorship (`EXECUTION`), and payment for another
sender (`PAYMENT`). The shared
[`PaymasterTestSuite`](../contracts/test/PaymasterTestSuite.sol) also requires all four example
paymasters to sponsor each migrated account. These are real contract/delegation and opcode
tests under synthetic `setFrameTx` context; they do not turn the migration fixtures into a
public-bundler or raw type-`0x06` end-to-end test.

## Boundaries that do not migrate automatically

ERC-4337 and EIP-8141 solve similar user problems with different state and trust boundaries.
Do not translate a `UserOperation` field-for-field into a Frame transaction.

- **Replay protection differs.** ERC-4337 stores a 192-bit nonce key plus 64-bit sequence in
  the EntryPoint. The current EIP-8141 envelope uses the sender account's scalar protocol
  nonce. A pending or consumed UserOperation nonce says nothing about the next Frame nonce.
- **Signature domains differ.** `userOpHash` commits to the EntryPoint and chain under
  ERC-4337. EIP-8141's canonical signature hash commits to the complete Frame envelope.
  Existing UserOperation or paymaster signatures cannot be replayed as Frame signatures.
- **Funding differs.** ERC-4337 deposits and paymaster stakes are balances in the EntryPoint.
  EIP-8141's payer is charged through `APPROVE` from the payer account's ETH balance. Withdraw
  or deliberately retain EntryPoint deposits; they do not become Frame payment capacity.
- **Paymaster interfaces differ.** `validatePaymasterUserOp`/`postOp`, `paymasterAndData`,
  EntryPoint deposits, and bundler reputation do not map to an EIP-8141 PAYMENT approval.
  A dual-mode paymaster needs independent validation, accounting, withdrawal, and replay
  protection for each path.
- **Execution callers differ.** ERC-4337 accounts commonly trust a singleton EntryPoint.
  Frame `VERIFY` code runs with the protocol `ENTRY_POINT` caller, while an approved `SENDER`
  frame executes with `tx.sender` as caller. Do not weaken an `onlyEntryPoint` modifier into a
  broad caller check just to make both paths pass.
- **Validation mutability differs.** EIP-8141 `VERIFY` frames have STATICCALL restrictions;
  `APPROVE` is the protocol-defined exception. A 4337 validator that increments its own nonce,
  consumes a recovery record, or writes session state during validation needs a read-only Frame
  policy or a separately authorized execution frame.

Before migrating, inventory every EntryPoint version, deposit, stake, paymaster, nonce key,
pending UserOperation, module, hook, guard, recovery path, role, allowance, and cross-chain
deployment associated with the account.

## Upgradeable ERC-4337 accounts: dual mode at one address

Preserve the existing 4337 surface while adding a narrow Frame surface.

1. **Freeze the storage layout.** Append new state or use namespaced storage; do not reorder
   proxy slots, owners, module lists, nonce data, or recovery state. Record the implementation
   and storage hashes that a rollback must restore.
2. **Keep `validateUserOp` unchanged.** Continue authenticating the configured EntryPoint,
   `userOpHash`, nonce scheme, prefund, and aggregator rules. A Frame path must not silently
   broaden what the old EntryPoint may execute.
3. **Add a Frame validation entry point.** Accept only the intended EIP-8141 signature index
   or index list, require the canonical-message policy, derive the exact allowed approval
   scope, and call `APPROVE`. Keep algorithm-specific policies explicit.
4. **Preserve execution hooks.** Retain the old EntryPoint-only executor for UserOperations.
   The safest Frame default is to reject arbitrary direct `SENDER` targets and require a
   `SENDER` frame targeting the account itself, calling a dedicated Frame dispatcher that
   reuses the existing execute/module/guard/spending-limit/event pipeline. Otherwise one
   transaction-wide execution approval lets later `SENDER` frames call applications directly,
   bypassing wallet bytecode and every hook it used to enforce. Keep EntryPoint and Frame caller
   checks separate and explicit.
5. **Make initialization signed and single-use.** Bind the account, chain, old and new
   implementation, complete owner/module configuration, initialization nonce, and deadline.
   Mark the migration version only through an authorized non-VERIFY action. Test replay and
   partial-initialization failures.
6. **Canary both rails.** Exercise self-payment, external Frame paymaster payment, 4337
   self-payment, and 4337 paymaster payment. Test paying for another account through direct or
   private inclusion too, but do not label an ordinary state-backed payer public-mempool
   compatible: its validation reads policy storage outside `tx.sender`. Default-code and the
   draft's exact canonical-paymaster path have different public-pool treatment. Compare events,
   module hooks, revert behavior, ETH debits, nonces, and recovery controls.
7. **Keep rollback funded.** Retain enough EntryPoint deposit and bundler support for an
   emergency UserOperation, and retain the proxy-admin or governance path needed to restore
   the prior implementation. A Frame failure must not be able to disable the old rail.
8. **Drain only after the rollback window.** Stop creating new UserOperations, wait for
   pending operations and replacement windows to clear, then withdraw obsolete EntryPoint
   deposits/stakes and retire old paymasters deliberately.

A safe dual-mode implementation has two small authenticated entry points converging on shared
wallet policy. It does not have one permissive function that guesses whether the caller meant
ERC-4337 or EIP-8141.

### Tested Kernel v3.3 path

The Kernel example applies that design to an actual upgradeable account:

- `KernelFactory` deterministically deploys the ERC-1967 proxy and initializes the real
  `ECDSAValidator` root. The fixture then mutates Kernel's namespaced nonce state, funds the
  account, and treats that fully initialized proxy as the already-deployed legacy starting
  point before any migration action.
- The configured EntryPoint calls Kernel's own `upgradeTo` to install
  `KernelV33FrameAccount`. The 1,014-byte shim declares no storage: it handles only
  `validate(uint256)` and delegates fallback/receive plus every legacy selector to the exact
  immutable pre-migration Kernel implementation. That preserves `validateUserOp`, ERC-7579
  modules, ERC-1271, execution, receive hooks, and Kernel's existing `upgradeTo` rollback
  surface instead of re-emitting the full Kernel runtime. A regression keeps the deployed
  shim below EIP-170's 24,576-byte limit.
- Frame validation re-reads Kernel's installed root, requires that exact ECDSA validator and
  Kernel's explicit no-hook sentinel, accepts only a canonical-message secp256k1 entry from
  its stored owner, and derives the approval scope from the current frame. A same-address P256
  identity cannot inherit the old root's authority. A root with an execution hook is refused
  because Frame SENDER execution cannot safely reproduce Kernel's 4337 hook lifecycle.
- The tests preserve the predicted address, proxy runtime, ETH balance, validation storage
  word, root identifier, invalidated nonce floor, validator-owned owner state, and EntryPoint.
  A correctly signed legacy `PackedUserOperation` remains valid after the upgrade, while a
  wrong-owner signature remains invalid through the delegated legacy path.
- Rolling the proxy back to the original Kernel implementation restores legacy-only behavior
  while retaining the root and validator state. The inherited suite exercises all three
  Frame roles, and every example paymaster sponsors the migrated proxy.

The legacy check calls the real Kernel `validateUserOp` as the configured EntryPoint with a
real owner signature. It proves that the account's ERC-4337 validation surface survives; it
does not simulate a complete EntryPoint handleOps flow, bundler admission, or aggregation.
The test compiles and deploys the legacy Kernel only to model an account that already exists:
under this repository's `@future` profile that fixture runtime is 29,741 bytes, and Forge's
test EVM permits the oversized setup deployment. A production migration starts from an
already-deployed, chain-valid Kernel; only the new 1,014-byte shim is a deployment artifact of
this migration, and its EIP-170 limit is enforced in the test.

## Non-upgradeable ERC-4337 accounts: migrate to a new address

Deployed non-upgradeable code cannot acquire a Frame validator at the same address. CREATE2
cannot overwrite it, and EIP-7702 authorizations apply only to empty or already delegated
accounts, not arbitrary deployed contract code.

1. Deploy and initialize a new Frame-capable account with the final owner, recovery, module,
   and paymaster policy. Fund it only enough for canary transactions.
2. Verify the address independently, on every target chain, before announcing or funding it.
3. Move permissions before assets where possible: add the new account to roles and safelists,
   test it, then remove the old account. For protocols that cannot overlap roles, schedule a
   tightly controlled atomic or governance transition.
4. Transfer ETH, tokens, NFTs, protocol positions, ENS controls, governance delegations, and
   off-chain allowlist identities. Revoke old allowances and session keys.
5. Clear pending UserOperations, withdraw the old account's EntryPoint deposit, and unwind
   paymaster stake/deposit only after its unstake delay and operational obligations permit it.
6. Leave a documented recovery window and a final sweep path. Do not destroy the old account
   while forgotten assets, refunds, bridge messages, or delayed claims can still arrive.

### Counterfactual factories and address promises

A counterfactual address is determined by the factory, salt, and initialization-code hash.
Changing constructor arguments, proxy bytecode, compiler metadata, or factory address changes
the result. A factory being deployed at the same address on several chains is insufficient if
its runtime, salt handling, or initialization sequence differs.

EIP-8141 permits a first deploy frame, but the public validation prefix constrains deployment
to deterministic behavior. An existing ERC-4337 factory may still reject the migration
because its caller changes from the ERC-4337 EntryPoint to EIP-8141's protocol
`address(0xaa)`. Preserving a counterfactual address requires reusing the exact same factory,
initcode, and salt, so any caller gate or caller-dependent initcode must be resolved without
changing those inputs. The current draft recommends the
[EIP-7997 deterministic factory](https://eips.ethereum.org/EIPS/eip-7997) as one deployment
example; this toolkit's availability of the familiar factory address is not proof of fork
activation or identical account nonce state.

For every chain, pin and test:

- factory address and runtime hash;
- salt derivation and owner/key domain separation;
- exact initcode hash and compiler settings;
- proxy implementation and initialization authorization;
- predicted address before any transfer or signed permission grant; and
- behavior when deployment is replayed, front-run, or the address already exists.

If cross-chain address stability matters, keep chain-specific configuration out of CREATE2
initcode where possible and apply it through a signed, one-time initializer. The initializer
must bind the predicted account and chain so another party cannot seize an uninitialized
counterfactual account.

## EOAs: default code requires no migration

An empty-code EOA can use EIP-8141's protocol default code at its existing address without a
deployment, storage copy, EntryPoint deposit, or delegation. It remains secured by the same
secp256k1 key: execution-and-payment approval selects signature index 0, while a PAYMENT-only
default-code frame selects index 1.

This is the lowest-risk compatibility path for an EOA that is not trying to retire ECDSA.
Legacy transactions and Frame transactions share the account nonce, so wallets must coordinate
pending queues and replacements across both formats. Test the first Frame transaction with a
small value and a conservative gas limit before changing the wallet's default submission path.

Default code is secp256k1-only. The toolkit-local ML-DSA scheme does not change that rule.

## EOAs: optional EIP-7702 dual-mode delegation

EIP-7702 can preserve the EOA address while pointing it at wallet code. Use a delegate built
and audited for both ordinary/set-code transaction calls and EIP-8141 frame dispatch; do not
delegate to a contract merely because its runtime happens to expose a compatible selector.

1. **Audit storage in the EOA context.** Delegated code uses the authority account's storage.
   Use namespaced layouts such as ERC-7201 and prove there are no collisions with previous or
   future delegates. Clearing a delegation does not clear its storage.
2. **Sign initialization, not only delegation.** An EIP-7702 authorization commits to chain,
   delegate address, and authority nonce, but not an arbitrary wallet configuration call.
   The delegate must require a separate signed, single-use initializer binding the authority,
   chain, delegate/runtime version, owners, modules, recovery policy, nonce, and deadline.
3. **Coordinate nonces globally.** Processing a valid authorization increments the authority
   nonce, and the outer transaction sender nonce is processed separately. Query fresh state
   immediately before signing. Pause or replace pending legacy, set-code, Frame, and 4337-via-
   7702 operations that could consume the same authority nonce.
4. **Canary with bounded authority.** Start with low balances and no unlimited token approvals.
   Test direct calls, sponsored calls, Frame VERIFY/SENDER behavior, reentrancy, module hooks,
   recovery, and initialization replay.
5. **Keep an explicit clear rollback.** A later authorization to the zero address clears the
   delegation indicator. Pre-signing a clear tuple is brittle because its nonce can become
   stale; maintain an operational path to obtain the current nonce and sign/broadcast the
   clear transaction. Remember that authorization processing is not rolled back when the
   outer transaction execution fails.

EIP-7702 does **not** retire the EOA's secp256k1 root. The protocol uses that key to authorize
the delegate, replace it, or clear it, so compromise of the original key remains decisive even
if the delegate accepts P256 or post-quantum signatures for daily execution. True ECDSA
retirement requires moving to a code account whose address is not governed by that EOA key,
or a future consensus mechanism for code-controlled delegation. This toolkit's provisional
EIP-7851 experiment is not an upstream production migration mechanism.

### Tested EIP-7702 path

The EOA fixture delegates the authority to `EOA7702FrameAccount` and proves:

- the EOA address and balance remain unchanged and its exact code is the 23-byte
  `0xef0100 || implementation` designator;
- the authority can still call its own delegated `execute` entry point, the downstream call
  retains the EOA as caller, and a third party cannot use that executor;
- Frame validation remains secp256k1-only, binds the signer to `address(this)`, and rejects a
  same-address P256 metadata collision instead of broadening the original EOA root;
- the inherited account suite covers `BOTH`, `EXECUTION`, and `PAYMENT`, and all four example
  paymasters sponsor the delegated EOA; and
- a signed zero-address authorization clears the delegation without moving funds, restoring a
  plain EOA rollback state.

The test uses `vm.signAndAttachDelegation` twice. Forge tracks the authority's successive
signed authorization nonces across active delegations, so the clear authorization follows the
installation authorization. The cheatcode mutates the delegation indicator directly; it does
**not** submit or execute a raw type-4 outer set-code transaction, and it does not emulate that
outer transaction's sender nonce increment. Production nonce planning must therefore account
separately for authorization processing and the outer transaction, as described above.

## Phased launch and rollback checklist

Use gates with observable exit criteria:

1. **Shadow:** build and simulate both paths against the same action corpus; reconcile
   authorization decisions, hooks, logs, gas payer, fees, and nonce results.
2. **Canary:** enable Frame submission for internal accounts and bounded value only. Keep the
   old 4337 or legacy route as the default.
3. **Dual mode:** route a small percentage to Frame, with automatic fallback only before a
   transaction is signed or broadcast. Never silently re-sign the same intent under a weaker
   policy.
4. **Primary:** make Frame the default after success-rate, fee, recovery, and monitoring
   targets hold through the chosen rollback window.
5. **Retire:** drain obsolete deposits and revoke old roles only after pending-operation,
   bridge, refund, and governance delays have elapsed.

Before each phase, rehearse rollback: proxy downgrade or module disable for an upgradeable
account, stop-and-sweep for a new-address migration, old-rail routing for default-code EOAs,
or a fresh-nonce zero-address EIP-7702 authorization for delegated EOAs. Record which keys,
services, balances, and chain conditions rollback requires; a rollback that depends on the
broken path is not a rollback.
