// Same account as account.yul, written with the patched-solc BUILTINS.
// Needs the fork at ../../solidity plus --experimental --evm-version @future.
//
// Not byte-identical to the verbatim version. The builtin `approvetx` is known
// to terminate control flow, so solc drops the unreachable trailing `revert`;
// `verbatim_3i_0o(hex"aa", ...)` is opaque to the compiler, which must assume
// execution falls through. See contracts/docs/02-yul-minimal-account.md.
//
// Compile:
//   solc --strict-assembly --experimental --evm-version @future --bin account-builtins.yul
//
// Naming: the APPROVE builtin is spelled `approvetx`, not `approve`, so that the
// bare name `approve` stays free for the ERC-20 method.
object "MinimalAccount" {
    code {
        datacopy(0, dataoffset("runtime"), datasize("runtime"))
        return(0, datasize("runtime"))
    }

    object "runtime" {
        code {
            // sigparam(signatureIndex, param) -- arguments in stack-table order,
            // same convention as verbatim. param 0x00 = resolved_signer.
            let signer := sigparam(0, 0x00)
            // param 0x02 = msg; zero means the canonical transaction hash.
            let signedThisTx := iszero(sigparam(0, 0x02))

            if and(eq(sload(0), signer), signedThisTx) {
                // approvetx(offset, length, scope); scope 3 = EXECUTION | PAYMENT.
                approvetx(0, 0, 3)
            }

            revert(0, 0)
        }
    }
}
