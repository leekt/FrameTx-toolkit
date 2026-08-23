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
            if iszero(calldatasize()) { stop() }

            // Compact account ABI: validate(uint256) is exactly the selector
            // followed by one selected signature index.
            if iszero(eq(calldatasize(), 0x24)) { revert(0, 0) }
            if iszero(eq(shr(224, calldataload(0)), 0xce4d01a3)) { revert(0, 0) }
            let signatureIndex := calldataload(0x04)

            // sigparam(signatureIndex, param) -- arguments in stack-table order,
            // same convention as verbatim. param 0x00 = resolved_signer.
            let signer := sigparam(signatureIndex, 0x00)
            // param 0x02 = msg; zero means the canonical transaction hash.
            let signedThisTx := iszero(sigparam(signatureIndex, 0x02))
            let scope := frameparam(txparam(0x0a), 0x06)
            if iszero(scope) { revert(0, 0) }

            if and(eq(sload(0), signer), signedThisTx) {
                approvetx(0, 0, scope)
            }

            revert(0, 0)
        }
    }
}
