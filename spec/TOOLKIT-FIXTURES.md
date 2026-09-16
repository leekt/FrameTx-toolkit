## Toolkit Appendix: Non-Normative Tooling-Fixture Profile

### Status and boundary

This appendix describes historical synthetic fixtures. Current EIP-8250 selectors and
EIP-8272 verifier frames are documented in [spec/README.md](README.md); the fixture
opcode RECENTROOTREFLOAD is not part of current EIP-8272.


This appendix documents only the context accepted by the toolkit's `setFrameTx` cheatcode
and revm host interface. It is not part of the normative EIP-8141 snapshot, does not
claim that EIP-8250, EIP-8272, or EIP-7906 has been merged into EIP-8141, and assigns no
transaction fields or unresolved wire constants.

In particular, the normative payload remains:

```text
[chain_id, nonce, sender, frames, signatures, fees, blob_versioned_hashes]
```

Its `nonce` is still the scalar nonce defined in the body, and its normative frame modes
remain `DEFAULT = 0`, `VERIFY = 1`, and `SENDER = 2`. None of the context-only values below
is added to that RLP payload or to `compute_sig_hash(tx)` by this appendix.

### Fixture context and `POST_TX`

The host or cheatcode may supply these additional context values directly:

| Context value | Introspection | Fixture meaning |
|---|---|---|
| recent-root references | `RECENTROOTREFLOAD` | Supplied `(source_id, slot, root)` records |
| transaction trace | `TXTRACE`, `TXDIFF`, `EVENTDATACOPY` | Supplied ordered diffs, deployments, events, gas pre-charge, and payer |

`setFrameTx` copies these values into the host context. It does not derive or validate the
recent roots or construct a trace from execution. Callers are responsible for supplying
internally consistent fixture data.

The fixture additionally recognizes frame mode `POST_TX = 3`. A current `POST_TX` target is
executed statically in the working-tree implementation, `APPROVE` is unavailable in that
mode, and `TXTRACE`, `TXDIFF`, and `EVENTDATACOPY` require the currently executing frame to
have mode `3`. This does not define where a `POST_TX` suffix belongs in a real transaction or
how its execution and rollback interact with the transaction body.

The fixture adds no root or trace `TXPARAM` selectors. The host implements EIP-8141
`0x00` through `0x0C` and current EIP-8250 `0x0D` through `0x10`. The Solidity cheatcode
currently supplies the scalar nonce as the legacy nonce and the baseline key set `[0]`;
raw keyed transactions supply the separate legacy nonce and actual keys. Every other
selector is undefined and exceptional-halts.

### Fixture opcode allocation, operands, and gas

The following allocation is local to the tooling fixture. Stack operands are listed top
first, matching the tables in the normative body:

| Opcode | Byte | Top-first stack input | Output | Availability | Working-tree gas |
|---|---|---|---|---|---|
| `RECENTROOTREFLOAD` | `0xb6` | `field, referenceIndex` | selected field | Any active fixture frame context | 3 |
| `TXTRACE` | `0xb7` | `index, param` | selected trace value | Current frame is `POST_TX` | provisional flat 100 |
| `TXDIFF` | `0xb8` | `param, address, in3` | selected direct/local value | Current frame is `POST_TX` | provisional warm total 100; direct state selectors add only the applicable cold EIP-2929 premium |
| `EVENTDATACOPY` | `0xb9` | `eventIndex, memOffset, dataOffset, length` | none | Current frame is `POST_TX` | 3 plus 3 per copied word and memory expansion |

An absent fixture context, an undefined selector, or an out-of-range index causes an
exceptional halt. `RECENTROOTREFLOAD` is not restricted to `POST_TX`. The `0xb6`-`0xb9`
allocation follows native `SIGDATACOPY` locally and makes no claim on final opcode allocation
by any upstream proposal.

### `RECENTROOTREFLOAD` fixture selectors

| `field` | Return value |
|---|---|
| `0x00` | supplied source identifier (`bytes32`) |
| `0x01` | supplied consensus slot |
| `0x02` | supplied opaque root (`bytes32`) |

An undefined field or out-of-range `referenceIndex` exceptional-halts. The records are opaque,
host-supplied fixture input; the fixture performs no source or root verification.

### `TXTRACE` fixture selectors

`index` is a global index into the ordered vector selected by `param`:

| `param` | Return value |
|---|---|
| `0x00` | balance-diff count; `index` must be zero |
| `0x01` | storage-diff count; `index` must be zero |
| `0x02` | deployed-contract count; `index` must be zero |
| `0x03` | balance-diff account |
| `0x04` | balance before the transaction |
| `0x05` | balance as supplied for the `POST_TX` frame |
| `0x06` | storage-diff account |
| `0x07` | storage key |
| `0x08` | storage value before the transaction |
| `0x09` | storage value as supplied for the `POST_TX` frame |
| `0x0A` | deployed-contract account |
| `0x0B` | deployed contract's supplied current code hash |
| `0x0C` | event count; `index` must be zero |
| `0x0D` | event emitter |
| `0x0E` | event topic count |
| `0x0F` | topic 0 |
| `0x10` | topic 1 |
| `0x11` | topic 2 |
| `0x12` | topic 3 |
| `0x13` | event data length |
| `0x14` | supplied gas pre-charge; `index` must be zero |
| `0x15` | supplied gas payer; `index` must be zero |

Requesting a topic that the selected event does not contain exceptional-halts.

### `TXDIFF` fixture selectors

| `param` | `in3` | Return value |
|---|---|---|
| `0x00` | storage key | value before the transaction |
| `0x01` | storage key | value as supplied for the `POST_TX` frame |
| `0x02` | zero | account balance before the transaction |
| `0x03` | zero | account balance as supplied for the `POST_TX` frame |
| `0x04` | zero | account code hash before the transaction |
| `0x05` | zero | account code hash as supplied for the `POST_TX` frame |
| `0x06` | zero | storage-diff count for `address` |
| `0x07` | address-local storage index | corresponding global `TXTRACE` storage index |
| `0x08` | zero | event count for `address` as emitter |
| `0x09` | address-local event index | corresponding global `TXTRACE` event index |
| `0x0A` | zero | change flags: nonce `0x1`, balance `0x2`, storage `0x4`, code hash `0x8` |

Direct selectors `0x00`-`0x05` access live host storage/account state on both supplied-diff
hits and misses. Their provisional 100 gas is the warm-access total; when that host access is
cold, only the applicable EIP-2929 cold premium is added. If the item is absent from the
supplied diff, the current live storage value, balance, or code hash is returned for both
views. Count and flag selectors require `in3 == 0`; an invalid local index exceptional-halts.

### Trace ordering and event data

The fixture expects net balance diffs, deployed contracts, and account diffs in ascending
address order; storage diffs in ascending `(address, key)` order; and events in global
emission order. Account diffs supply nonce-change and before/after code-hash information,
while balance and storage before/after values live in their dedicated vectors. The fixture
derives emitter-local event indexes from the supplied global event list.

`EVENTDATACOPY` copies non-indexed bytes from one supplied event. Unlike
`FRAMEDATACOPY` and `SIGDATACOPY`, it has strict source bounds:
`dataOffset + length` must not exceed the selected event's data length. An overrun or invalid
event index exceptional-halts; bytes are not zero-filled past the source.

### Integration intentionally left pending

This fixture profile does **not** implement or specify:

- keyed-nonce wire fields, canonical encoding, state storage, validation, first-use charging,
  transaction-pool identity, or replacement rules;
- recent-root wire fields, signature-hash commitment, pre-execution verification, source
  registry, or system-contract behavior;
- normative placement or validation of `POST_TX` frames, trace construction from actual
  execution, execution-body rollback, or gas settlement for those frames;
- public-mempool rules, network propagation, RPC encoding, or per-frame receipts for the
  fixture extensions.

Until those pieces are specified and implemented, B6-B9 and the extended context are suitable
only for compiler, interpreter, library, and account-fixture experiments.

## Copyright

Copyright and related rights waived via [CC0](../LICENSE.md).
