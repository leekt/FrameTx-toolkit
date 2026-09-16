#!/usr/bin/env python3
"""Independent RLP encoder for the EIP-8250 frame-transaction
envelope, used to pin `foundry-primitives`' `KEYED_RAW` golden vector.

Current EIP-8250 payload, pinned on 2026-09-15. Pure Python, no keccak:
it produces the raw bytes; Rust tests check signing and transaction hashing.

  raw = 0x06 || rlp([chain_id, nonce_keys, nonce_seq, sender, frames, signatures,
                     [max_priority_fee, max_fee, max_blob_fee], blob_hashes])
  frame     = [mode, flags, target_or_empty, [execution, state], value, data]
  signature = [scheme, signer, msg, signature_bytes]
"""

def rlp_bytes(b: bytes) -> bytes:
    if len(b) == 1 and b[0] < 0x80:
        return b
    if len(b) < 56:
        return bytes([0x80 + len(b)]) + b
    lb = len(b).to_bytes((len(b).bit_length() + 7) // 8, "big")
    return bytes([0xB7 + len(lb)]) + lb + b

def rlp_list(items) -> bytes:
    body = b"".join(items)
    if len(body) < 56:
        return bytes([0xC0 + len(body)]) + body
    lb = len(body).to_bytes((len(body).bit_length() + 7) // 8, "big")
    return bytes([0xF7 + len(lb)]) + lb + body

def rlp_int(x: int) -> bytes:
    return rlp_bytes(b"" if x == 0 else x.to_bytes((x.bit_length() + 7) // 8, "big"))

def frame(mode, flags, target, execution, state, value, data):
    tgt = rlp_bytes(target) if target is not None else rlp_bytes(b"")
    return rlp_list([rlp_int(mode), rlp_int(flags), tgt,
                     rlp_list([rlp_int(execution), rlp_int(state)]),
                     rlp_int(value), rlp_bytes(data)])

def signature(scheme, signer, msg, sig):
    return rlp_list([rlp_int(scheme), rlp_bytes(signer), rlp_bytes(msg), rlp_bytes(sig)])

def envelope(chain_id, nonce_keys, nonce_seq, sender, frames, signatures,
             max_priority_fee, max_fee, max_blob_fee, blob_hashes):
    return bytes([0x06]) + rlp_list([
        rlp_int(chain_id),
        rlp_list([rlp_int(k) for k in nonce_keys]),
        rlp_int(nonce_seq),
        rlp_bytes(sender),
        rlp_list(frames),
        rlp_list(signatures),
        rlp_list([rlp_int(max_priority_fee), rlp_int(max_fee), rlp_int(max_blob_fee)]),
        rlp_list([rlp_bytes(h) for h in blob_hashes]),
    ])

if __name__ == "__main__":
    # Mirrors `keyed_sample()` in foundry/crates/primitives/src/transaction/frame.rs.
    raw = envelope(
        chain_id=31337,
        nonce_keys=[1, 1 << 255],
        nonce_seq=7,
        sender=bytes([0x11]) * 20,
        frames=[
            frame(1, 3, None, 50_000, 0, 0, bytes([1, 2, 0, 3])),
            frame(2, 0, bytes([0x22]) * 20, 21_000, 200_000, 1_000, b""),
        ],
        signatures=[signature(1, b"", b"", bytes([0xAB]) * 65)],
        max_priority_fee=1_000_000_000,
        max_fee=2_000_000_000,
        max_blob_fee=0,
        blob_hashes=[],
    )
    print(raw.hex())
