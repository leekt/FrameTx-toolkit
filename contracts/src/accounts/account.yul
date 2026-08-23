// Minimal EIP-8141 smart account, standalone Yul, PORTABLE spelling.
//
// The frame opcodes are emitted with `verbatim_*`, so this file compiles with any
// stock solc >= 0.8.5. No compiler fork, no --evm-version flag, no builtin names.
// See account-builtins.yul for the same account written with the patched-solc
// builtins, and contracts/docs/02-yul-minimal-account.md for a side-by-side.
//
// Compile:
//   solc --strict-assembly --bin account.yul
object "MinimalAccount" {
    // Constructor: copy the runtime object into memory and return it.
    // Storage slot 0 (the owner) is NOT initialized here -- deploy with the
    // owner pre-seeded by a factory, or add an sstore. Kept out to stay minimal.
    code {
        datacopy(0, dataoffset("runtime"), datasize("runtime"))
        return(0, datasize("runtime"))
    }

    object "runtime" {
        code {
            // Empty calldata is the funding path. Validation uses the compact
            // `validate(uint256)` ABI below and therefore never arrives empty.
            if iszero(calldatasize()) { stop() }

            // validate(uint256) is exactly selector | signatureIndex. Requiring
            // 36 bytes rejects short, dynamic-array, and trailing encodings.
            if iszero(eq(calldatasize(), 0x24)) { revert(0, 0) }
            if iszero(eq(shr(224, calldataload(0)), 0xce4d01a3)) { revert(0, 0) }
            let signatureIndex := calldataload(0x04)

            // --- verbatim argument order --------------------------------------
            // For verbatim_Ni_Mo the FIRST argument is pushed LAST, so it ends up
            // on TOP of the stack. The argument list therefore reads top-first,
            // exactly like the stack tables in the EIP. Verified by compiling
            // verbatim_3i_0o(hex"aa", 0x11, 0x22, 0x33) with --asm: the emitted
            // code is `6033 6022 6011 aa`.
            //
            // SIGPARAM (0xb4), stack top-first: signatureIndex, param -> value
            //   signatureIndex      -> the selected entry in tx.signatures
            //   param          = 0  -> resolved_signer
            //
            // This is the whole point of EIP-8141 account validation: the
            // protocol has ALREADY verified every supported native signature in
            // the envelope against its selected message before this frame runs.
            // That includes the toolkit-local ML-DSA-44 profile. The account asks
            // which key signed, then below requires that the selected message was
            // this transaction's hash.
            let signer := verbatim_2i_1o(hex"b4", signatureIndex, 0x00)

            // param = 0x02 -> msg. Zero is the reserved EVM representation for
            // an empty msg, meaning this entry signed the canonical transaction
            // hash. An explicit digest does not bind the frame list.
            let signedThisTx := iszero(verbatim_2i_1o(hex"b4", signatureIndex, 0x02))

            // FRAMEPARAM(current frame, 0x06) is flags & 0x3: BOTH for a
            // self-relay, EXECUTION with a paymaster, or PAYMENT when this
            // account pays for another sender.
            let frameIndex := verbatim_1i_1o(hex"b0", 0x0a)
            let scope := verbatim_2i_1o(hex"b3", frameIndex, 0x06)
            if iszero(scope) { revert(0, 0) }

            // Read-only: this frame runs as a VERIFY frame, i.e. under
            // STATICCALL rules. SLOAD is fine; SSTORE / LOG / state-changing
            // calls are not. APPROVE is the single protocol-blessed exception.
            if and(eq(sload(0), signer), signedThisTx) {
                // APPROVE (0xaa), stack top-first: offset, length, scope
                //   offset = 0, length = 0 -> empty return data (RETURN semantics)
                //   scope  = frame.flags & 0x3
                // APPROVE exits the frame successfully, so nothing below runs.
                verbatim_3i_0o(hex"aa", 0, 0, scope)
            }

            // Wrong signer -> revert -> the WHOLE transaction is invalid.
            revert(0, 0)
        }
    }
}
