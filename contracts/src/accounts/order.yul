// Argument-order probe for verbatim. See README.md, "Verbatim argument order".
//   solc --strict-assembly --asm --bin order.yul
// Emits `603360226011aa`: the LAST argument is pushed FIRST, so the FIRST
// argument (0x11) is on top of the stack when the opcode runs.
object "O" { code { verbatim_3i_0o(hex"aa", 0x11, 0x22, 0x33) } }
