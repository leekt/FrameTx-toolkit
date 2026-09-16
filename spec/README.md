# FrameTx specification baseline

Checked **2026-09-16** against immutable upstream sources. The active AA set is **8141,
7906, 8250, 8272, 8298, and 8151**. PFI proposals are eligible; DFI proposals are excluded.
EIP-7997 remains a deployment dependency. Already adopted EIP-7702 and EIP-7951 remain
available for delegated accounts and P256/WebAuthn verification.

[Source pins and SHA-256 checksums](sources.json) identify byte-for-byte snapshots under
[`upstream/`](upstream/). [Fork inclusion decisions](inclusion.json) are pinned separately:
EIP document status (such as Draft) is not fork-inclusion status (PFI/CFI/SFI/DFI).
The check covers **44 EIPs**, including the complete `requires` dependency chain and
vFrame's EIP-712/EIP-1153 dependencies, plus **9 fork-inclusion records** with checksummed
status-history extracts. Inclusion records retain the upstream file hashes as provenance.
See the [2026-09-16 review](reviews/2026-09-16.md) for changes and implementation boundaries.

| EIP | Inclusion | Current specification | Toolkit boundary |
|---|---|---|---|
| [8141](https://eips.ethereum.org/EIPS/eip-8141) | Hegotá SFI | Seven-field envelope, nested fees and execution/state limits; native SIGDATACOPY; EIP-7778 block accounting | Compiler, REVM, Forge and opt-in Anvil. Opcode-level EIP-8037 and public-mempool policy remain incomplete. |
| [7906](https://eips.ethereum.org/EIPS/eip-7906) | Hegotá PFI | Read-only trailing POST_TX frames; failed assertions roll back the execution body while retaining validation and gas payment | TXTRACE/TXDIFF/EVENTDATACOPY host fixtures only. No raw POST_TX execution or trace construction. Bytes/gas remain toolkit-local where upstream leaves assignments TBD. |
| [8250](https://eips.ethereum.org/EIPS/eip-8250) | Hegotá PFI | Replace nonce with nonce_keys and nonce_seq; preserve nested fees; first-use keys cost 97,920 state gas each | Current keyed envelope and Anvil nonce bookkeeping. Local opt-in accepts scalar 8141 and keyed 8250 layouts; activation-boundary eviction and keyed public-pool replacement are not modeled. |
| [8272](https://eips.ethereum.org/EIPS/eip-8272) | Hegotá PFI | Leading VERIFY frame at 0x8272 with 72-byte tuples; ordinary EVM gas; EIP-7843 slotNumber; no new payload field, TXPARAM or opcode | Tuple encoding helper and spec tracked. Canonical RECENT_ROOT_CODE is TBD; no automatic verifier installation or native write shortcut. Historical root introspection remains a synthetic fixture only. |
| [8298](https://eips.ethereum.org/EIPS/eip-8298) | Hegotá PFI | Runtime-only SETCODEFROM adopts regular deployed code; same frame keeps its loaded code; later calls see the update | Spec tracked, execution not implemented. SETCODEFROM_OPCODE is TBD; no provisional opcode is assigned. |
| [8151](https://eips.ethereum.org/EIPS/eip-8151) | Hegotá PFI | ecRecover checks recovered account raw code; accepts empty/exact ef0100 designation; adds 100/2600 gas on successful recovery | Existing opt-in compiler/REVM/Foundry support. Does not follow the delegation target. |

The latest inclusion records come from
[ethereum/forkcast](https://github.com/ethereum/forkcast/tree/ccfe45542b0753d3c7fd2c4a59411febeb883ac8/src/data/eips).
EIP-7819 and EIP-7851 were declined for Hegotá at
[ACDE 245, 2026-09-10](https://forkcast.org/calls/acde/245/). Their compiler opcodes,
REVM implementations, Anvil flags, and Solidity helpers are removed. EIP-8298 is tracked
as the selected code-reuse/migration proposal; it is not an opcode-compatible replacement.
The exact upstream EIP-8141 snapshot still mentions SETDELEGATE in its mempool rules;
that reference does not re-enable the declined proposal in this toolkit.

## Breaking changes from the old devnet profile

- The keyed payload is `[chain_id, nonce_keys, nonce_seq, sender, frames, signatures,
  fees, blob_versioned_hashes]`. The old flat-fee payload with trailing root references
  is rejected. Existing signatures must be regenerated against the new encoding.
- EIP-8250 selectors are `0x0D = pre-state legacy nonce`, `0x0E = key count`,
  `0x0F = keys hash`, and `0x10 = first key`. `0x0C` remains frame state gas.
- Fresh keyed-nonce slots consume state gas in the approving frame, rather than a
  20,000 execution-gas surcharge. Zero-key transactions keep ordinary account-nonce behavior.
- EIP-8272 root tuples belong in verifier-frame calldata, not in the transaction envelope.
  The former special intrinsic charge, native root writer, and block-number-as-slot fallback
  are removed. The verifier's execution limit counts toward MAX_VERIFY_GAS.
- EIP-7906's specification and security prose still contain inconsistent descriptions of
  POST_TX rollback. The normative mode rules retain validation/payment and revert the
  execution body. The toolkit does not implement raw POST_TX and does not claim otherwise.
- EIP-8037 now caps ordinary transaction gas_limit at 2**32-1. EIP-8141 still explicitly
  bounds summed frame budgets below 2**64 and execution by EIP-7825. This toolkit follows
  the frame-specific constraints rather than silently applying the ordinary scalar cap.

## Checking for drift

```bash
tools/check-spec-drift.sh                  # all selected proposals and dependencies
tools/check-spec-drift.sh --offline        # verify local snapshot checksums
tools/check-spec-drift.sh --diff 8141 8250 # inspect selected upstream changes
```

The checker resolves EIPs master and Forkcast main once each, then fetches files at those
immutable revisions. It checks source hashes, required-dependency coverage, the EIP-8141
canonical copy, and inclusion status/call/date against verified evidence. The default
run also checks the two declined proposals for changes. It never changes the pins.
Review [VERSIONS.md](../VERSIONS.md) before advancing a source or toolchain revision.
