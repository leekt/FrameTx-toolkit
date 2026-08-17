# Writing EIP-8141 accounts

## The one idea to internalise

**The protocol verifies signatures before any of your code runs, but your account must check
what each signature signed.**

Every `SECP256K1` and `P256` entry is checked before frame execution. An entry with empty
`msg` is checked against the canonical transaction signature hash; an entry with a 32-byte
`msg` is checked against that explicit digest. Both are protocol-valid. Only the empty-`msg`
case necessarily commits to this transaction's frame list.

So an account does not do elliptic-curve work. It asks *which key signed*, requires that the
entry signed this transaction, and then decides whether it trusts that key:

```solidity
let signer := sigparam(0, 0x00)                 // resolved_signer of entry 0
let signedThisTx := iszero(sigparam(0, 0x02))   // empty msg => canonical tx hash
if and(eq(signer, sload(0)), signedThisTx) {
    approvetx(0, 0, 3)
}
```

That is the whole validation path for a single-owner account. Omitting the `0x02` check
would let a valid owner signature over an unrelated explicit digest authorize replaceable
`SENDER` frames. Compare with ERC-4337, where the account also parses a signature blob and
runs `ecrecover` itself.

## The opcodes

Stack is listed **top first**, matching the spec's tables and the order you write arguments
in Yul. `APPROVE` through `SIGDATACOPY` are the pinned EIP-8141/native-SIGDATACOPY surface.
The `0xb6`-`0xb9` rows are the toolkit's non-normative tooling-fixture profile, not additions
to the transaction encoding in the normative spec body.

| Opcode | Byte | Builtin | Stack | Returns |
|---|---|---|---|---|
| `APPROVE` | `0xaa` | **`approvetx`** | offset, length, scope | — (exits the frame) |
| `TXPARAM` | `0xb0` | `txparam` | param | value |
| `FRAMEDATALOAD` | `0xb1` | `framedataload` | offset, frameIndex | word |
| `FRAMEDATACOPY` | `0xb2` | `framedatacopy` | memOffset, dataOffset, length, frameIndex | — |
| `FRAMEPARAM` | `0xb3` | `frameparam` | frameIndex, param | value |
| `SIGPARAM` | `0xb4` | `sigparam` | signatureIndex, param | value |
| `SIGDATACOPY` | `0xb5` | `sigdatacopy` | memOffset, dataOffset, length, signatureIndex | — |
| `RECENTROOTREFLOAD` | `0xb6` | `recentrootrefload` | field, referenceIndex | value |
| `TXTRACE` | `0xb7` | `txtrace` | index, param | value |
| `TXDIFF` | `0xb8` | `txdiff` | param, address, in3 | value |
| `EVENTDATACOPY` | `0xb9` | `eventdatacopy` | eventIndex, memOffset, dataOffset, length | — |

> **`approvetx`, not `approve`.** The spec calls the opcode `APPROVE`, but `approve` is the
> ERC-20 method name and appears in a large share of deployed Solidity. Reserving it as a
> builtin would break existing contracts, so this fork spells it `approvetx`. The opcode
> byte `0xaa` is unchanged. `approve` remains free for your own functions and variables.

### Parameter tables

Normative `TXPARAM`: `0x00` tx type · `0x01` scalar wire `nonce` · `0x02` sender ·
`0x03`-`0x05` fee fields · `0x06` max cost · `0x07` blob count · `0x08` **canonical
signature hash** · `0x09` frame count · `0x0A` current frame index · `0x0B` signature
count. Other selectors are undefined in the pinned EIP-8141 body.

Non-normative fixture `TXPARAM` extensions: the supplied context treats `0x01` as a shared
keyed-nonce sequence and adds `0x0C` sender legacy nonce · `0x0D` supplied nonce-key count ·
`0x0E` supplied nonce-key hash · `0x0F` supplied recent-root-reference count · `0x10` first
supplied nonce key. `0x10` halts for an empty list; `0x11` is undefined and halts. These
values come from `setFrameTx`/host context; they are not extra fields in the current RLP
payload and the fixture does not implement keyed-nonce state transitions.

`FRAMEPARAM`: `0x00` resolved_target · `0x01` gas_limit · `0x02` mode · `0x03` flags ·
`0x04` len(data) · `0x05` status (halts for the current or a later frame) · `0x06`
allowed_scope · `0x07` atomic_batch · `0x08` value. Modes `0`-`2` are the normative
`DEFAULT`, `VERIFY`, and `SENDER` values; mode `3` (`POST_TX`) exists only in the fixture
profile described below.

`SIGPARAM`: `0x00` resolved_signer · `0x01` scheme · `0x02` msg · `0x03` len(signature).

`SIGDATACOPY` reads only `ARBITRARY` signature bytes. It zero-fills past the end like
`CALLDATACOPY` and exceptional-halts for protocol-validated schemes. On **stock** solc,
standalone Yul can emit it as
`verbatim_4i_0o(hex"b5", memOffset, dataOffset, length, sigIdx)`.

The rest of this subsection describes only the non-normative fixture profile.

`RECENTROOTREFLOAD`: `0x00` source id · `0x01` consensus slot · `0x02` opaque root. It costs
3 gas. An undefined field or out-of-bounds supplied reference index exceptional-halts. The
fixture does not verify roots or define their wire encoding.

`TXTRACE` costs a provisional flat 100 gas and is valid only in the current `POST_TX` frame
(`mode == 3`). Its `index` is a global index into the relevant supplied trace vector:

| Param | Result |
|---|---|
| `0x00` | Balance-diff count (`index` must be zero) |
| `0x01` | Storage-diff count (`index` must be zero) |
| `0x02` | Deployed-contract count (`index` must be zero) |
| `0x03` / `0x04` / `0x05` | Balance entry account / before / after |
| `0x06` / `0x07` / `0x08` / `0x09` | Storage entry account / key / before / after |
| `0x0A` / `0x0B` | Deployed account / current code hash |
| `0x0C` | Event count (`index` must be zero) |
| `0x0D` / `0x0E` | Event emitter / topic count |
| `0x0F` / `0x10` / `0x11` / `0x12` | Event topic 0 / 1 / 2 / 3 |
| `0x13` | Event data length |
| `0x14` / `0x15` | Gas pre-charge / gas payer (`index` must be zero) |

`TXDIFF` is also `POST_TX`-only. Its provisional 100 gas is the warm total. Direct storage,
balance, and code-hash selectors access live host state on both supplied-diff hits and misses;
only the applicable EIP-2929 cold premium is added when that access is cold. The address-local
count selectors require `in3 == 0`; the index selectors take an address-local index and return
its global `TXTRACE` index:

| Param | `in3` | Result |
|---|---|---|
| `0x00` / `0x01` | Storage key | Storage value before / after |
| `0x02` / `0x03` | Zero | Account balance before / after |
| `0x04` / `0x05` | Zero | Account code hash before / after |
| `0x06` | Zero | Storage-diff count for address |
| `0x07` | Local storage index | Global storage-diff index |
| `0x08` | Zero | Event count for emitter |
| `0x09` | Local event index | Global event index |
| `0x0A` | Zero | Change flags: nonce `0x1`, balance `0x2`, storage `0x4`, code hash `0x8` |

`EVENTDATACOPY` is `POST_TX`-only. It costs 3 plus 3 per copied word and memory expansion,
and has strict source bounds: `dataOffset + length` must not exceed the selected event's data
length. It exceptional-halts instead of zero-filling an overrun.

On stock solc, standalone Yul can emit the four fixture-profile opcodes as
`verbatim_2i_1o(hex"b6", field, referenceIndex)`,
`verbatim_2i_1o(hex"b7", index, param)`,
`verbatim_3i_1o(hex"b8", param, account, in3)` and
`verbatim_4i_0o(hex"b9", eventIndex, memOffset, dataOffset, length)`.

Rather than remembering operand orders, Solidity accounts can use
[`contracts/src/frame/FrameTxLib.sol`](../contracts/src/frame/FrameTxLib.sol), which wraps
every defined introspection selector, all copy opcodes and `APPROVE` in typed internal
functions — see
[contracts/docs/07](../contracts/docs/07-frametx-library.md).

## APPROVE scopes

| Scope | Meaning | Requires |
|---|---|---|
| `0x0` | nothing | — |
| `0x1` | PAYMENT | `sender_approved` already true; payer holds `max_cost` |
| `0x2` | EXECUTION | `resolved_target == tx.sender` |
| `0x3` | both | `resolved_target == tx.sender`; holds `max_cost` |

The requested scope must be a **subset** of the frame's `flags & 0x3`, or `APPROVE` reverts.
Setting flags to `0x3` and calling `approvetx(0, 0, 1)` is fine; the reverse is not.

## Constraints that will bite you

**A VERIFY frame is a STATICCALL.** No `SSTORE`, no `TSTORE`, no logs, no state-changing
calls. `APPROVE` is the sole exception. Any validation that wants scratch storage has to be
restructured — the multisig example works around exactly this.

**A reverting VERIFY frame invalidates the entire transaction**, not just that frame. There
is no partial success and no receipt to inspect.

**`sender_approved` is transaction-scoped, not per-frame.** Once granted, *every* subsequent
`SENDER` frame runs as `tx.sender` — not just the one the validator looked at. A validator
that approves without committing to the full frame list authorises an open-ended set of
calls. The accounts in this toolkit require the canonical signature hash, which covers the
whole frame list. The session-key example additionally walks every frame to impose a narrower
target/selector/value policy.

**A function calling `approvetx` cannot be `view`.** It changes state: it bumps the sender's
nonce, sets the payer and collects `max_cost`. Functions using only the introspection
opcodes cannot be `pure` but can be `view`.

## Compiling

```bash
solidity/build/solc/solc --experimental --evm-version @future --bin-runtime --optimize Account.sol
```

Standalone Yul, which works on **stock** solc too via `verbatim`:

```bash
solidity/build/solc/solc --strict-assembly --bin account.yul
```

`verbatim` argument order: the **first** argument ends up on **top** of the stack, so the
argument list reads in the same order as the spec's stack table. Verified —
`verbatim_3i_0o(hex"aa", 0x11, 0x22, 0x33)` compiles to `6033 6022 6011 aa`.

> `verbatim` is **not** available inside Solidity `assembly {}` blocks on any solc, stock or
> forked — it is a Yul-dialect builtin only. That limitation is the entire reason this fork
> exists.

## Testing an account

Accounts are tested with `forge`, using the patched build. `contracts/test/FrameTest.sol`
is the base class:

```solidity
contract MyAccountTest is FrameTest {
    address constant ACCOUNT = address(0xACC0);

    function setUp() public {
        deployAccount("MyAccount", ACCOUNT);   // etches the compiled runtime
        vm.store(ACCOUNT, bytes32(0), bytes32(uint256(uint160(OWNER))));
    }

    function test_ownerApproves() public {
        IFrameVm.FrameTx memory ctx = verifyContext(ACCOUNT, SCOPE_BOTH, bytes32(0));
        ctx.signatures = new IFrameVm.FrameTxSignature[](1);
        ctx.signatures[0] = secpSig(OWNER); // msgHash == 0: canonical transaction hash
        assertApproves(ACCOUNT, ctx, "owner should approve");
    }
}
```

`vm.setFrameTx` installs the transaction context so the frame opcodes resolve; execution is
real, not mocked.

> [!warning] Always include a positive case
> `assertRefuses` passes if the call fails for *any* reason, including the account never
> being deployed. A file of only negative assertions is green and worthless. Every test file
> must contain at least one `assertApproves` proving the setup is genuinely correct.

## Reproducible bytecode

The generated examples compile with `--no-cbor-metadata`. Without it solc appends a CBOR
trailer containing compiler/source metadata; changing the compiler build or source then
changes that trailer as well as any changed code. Removing it makes each documented size
refer only to executable runtime bytecode:

```bash
solc --experimental --evm-version @future --bin-runtime --optimize --no-cbor-metadata Account.sol
```

For deployment you generally *want* metadata. The toolkit omits it only from generated
`out-frame` artifacts so their byte counts and bytecode comparisons have one unambiguous
meaning; no current artifact-size claim includes a CBOR trailer.
