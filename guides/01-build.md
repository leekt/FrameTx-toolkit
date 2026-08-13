# Building the toolkit

Two components: a patched **Foundry** (whose revm executes the frame opcodes) and a patched
**solc** that compiles contracts using them. Build both; the tests need both.

## Clone with submodules

```bash
git clone --recurse-submodules https://github.com/leekt/FrameTx-toolkit.git
cd FrameTx-toolkit
```

Already cloned without `--recurse-submodules`:

```bash
git submodule update --init --recursive
```

Both submodules are pinned to exact commits (see [VERSIONS.md](../VERSIONS.md)). That is
deliberate — `git submodule update` restores the tested combination.

## Foundry

Rust toolchain. A cold build takes roughly 15 minutes.

```bash
cd foundry
cargo build --bin forge --release
```

The binary lands at `foundry/target/release/forge`. Use that one -- a
stock `forge` cannot execute the frame opcodes.

```bash
cd ../contracts
SOLC=../solidity/build/solc/solc ./script/build-frame-accounts.sh
../foundry/target/release/forge test        # 53 tests
```

## solc

Needs CMake ≥3.21, a C++20 compiler, and Boost ≥1.83.

```bash
# macOS
brew install boost cmake ninja ccache

# Debian/Ubuntu
sudo apt-get install -y build-essential cmake ninja-build ccache libboost-all-dev
```

```bash
cd solidity
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
cmake --build build --target solc -j "$(nproc 2>/dev/null || sysctl -n hw.ncpu)"
```

The binary lands at `solidity/build/solc/solc`. A cold build takes roughly 10–20 minutes.

Verify it has the new opcodes:

```bash
cat > /tmp/t.sol <<'EOF'
contract T { function f() external { assembly { approvetx(0, 0, 3) } } }
EOF
solidity/build/solc/solc --experimental --evm-version @future --bin /tmp/t.sol
```

Compiles → the fork works. `Function "approvetx" not found` → you built stock solc.

### Why `--experimental --evm-version @future`

EIP-8141 is a draft with no assigned hard fork, so the opcodes are gated behind solc's
existing experimental `@future` EVM version. That flag combination is upstream behaviour,
not something this fork added: `@future` always requires `--experimental`.

Without the flags the opcodes do not exist, and their names stay free for ordinary use —
which is the point of gating them.

## Optional: solc's own test suite

```bash
cd solidity
cmake --build build --target isoltest -j 8
./build/test/tools/isoltest --testpath test --no-semantic-tests --no-color < /dev/null
```

Semantic tests need `libevmone`, which is not required for anything here.

To run the EIP-8141 tests specifically (they are skipped by default because they require
`@future`):

```bash
./build/test/tools/isoltest --testpath test --no-semantic-tests --no-color \
    --evm-version @future -t "syntaxTests/inlineAssembly/frame_transaction*" < /dev/null
```
