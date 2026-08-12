// Minimal EIP-8141 smart account, standalone Yul, PORTABLE spelling.
//
// The frame opcodes are emitted with `verbatim_*`, so this file compiles with any
// stock solc >= 0.8.5. No compiler fork, no --evm-version flag, no builtin names.
// See account-builtins.yul for the same account written with the patched-solc
// builtins, and README.md for a side-by-side of the two.
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
            // --- verbatim argument order --------------------------------------
            // For verbatim_Ni_Mo the FIRST argument is pushed LAST, so it ends up
            // on TOP of the stack. The argument list therefore reads top-first,
            // exactly like the stack tables in the EIP. Verified by compiling
            // verbatim_3i_0o(hex"aa", 0x11, 0x22, 0x33) with --asm: the emitted
            // code is `6033 6022 6011 aa`.
            //
            // SIGPARAM (0xb4), stack top-first: signatureIndex, param -> value
            //   signatureIndex = 0  -> the first entry in tx.signatures
            //   param          = 0  -> resolved_signer
            //
            // This is the whole point of EIP-8141 account validation: the
            // protocol has ALREADY verified every secp256k1/P256 signature in the
            // envelope against the canonical signature hash before this frame
            // runs. The account never calls ecrecover; it only asks "which key
            // signed?" and decides whether it trusts that key.
            let signer := verbatim_2i_1o(hex"b4", 0, 0x00)

            // Read-only: this frame runs as a VERIFY frame, i.e. under
            // STATICCALL rules. SLOAD is fine; SSTORE / LOG / state-changing
            // calls are not. APPROVE is the single protocol-blessed exception.
            if eq(sload(0), signer) {
                // APPROVE (0xaa), stack top-first: offset, length, scope
                //   offset = 0, length = 0 -> empty return data (RETURN semantics)
                //   scope  = 3             -> APPROVE_EXECUTION_AND_PAYMENT
                // Requires frame.flags & 0x3 == 0x3 and resolved_target == tx.sender.
                // APPROVE exits the frame successfully, so nothing below runs.
                verbatim_3i_0o(hex"aa", 0, 0, 3)
            }

            // Wrong signer -> revert -> the WHOLE transaction is invalid.
            revert(0, 0)
        }
    }
}
