# Building the toolkit

The stack has four source components: patched **solc**, patched **revm**, patched
**foundry-core**, and **Foundry** built against the latter two. solc produces the account
artifacts; foundry-core exposes the experimental compiler target; the patched Forge executes
the artifacts. Artifact generation must happen before `forge test`.

## Reproducibility

The root gitlinks, Foundry's twelve REVM manifest patches, and `Cargo.lock` record the exact
current stack in [VERSIONS.md](../VERSIONS.md). A fresh recursive clone reproduces it:

- Solidity `cc3e100a84ab68aca75a2b48e576cfbcc7237caf` is rebased onto upstream
  `f985208342dc9d695a9097caf8206b11024df979`.
- revm `cad0e9fc012f790719791ff274b76eb852689559` is rebased onto upstream
  `17a323dac0f893aef6a29d48692185495b366149`.
- foundry-core `f415f6fef0a62f44c7faa83daa8e37b14f0e009b` is rebased onto upstream
  `78e5b57f86986eabd969a5fdf238b8159f7086fd`.
- Foundry `ffe76454940945b3b8ae6c7a6a0ae2939b4ff126` is rebased onto upstream
  `8bb78aeceda2eca7837d385e4f5bd39d6fc8bc71`.

All four submodules use the pushed `feat/eip8141-current-spec` branch. Foundry promotion
passed 30/30 primitives, 44/44 Anvil unit, and 31/31 Anvil integration tests. The root
gitlinks pin these commits; `git submodule update --init --recursive` checks out the
recorded stack. For update discovery, the repository's sync command fetches
remote refs without automatically replacing the recorded checkouts.

Follow the build order below from a fresh clone.

Clone and initialize the recorded stack:

```bash
git clone --recurse-submodules https://github.com/leekt/FrameTx-toolkit.git
cd FrameTx-toolkit
```

For an existing clone:

```bash
git submodule update --init --recursive
```

The sequence below is the required build order.

## 1. Build solc

solc needs CMake >=3.21, a C++20 compiler, and Boost >=1.83.

```bash
# macOS
brew install boost cmake ninja ccache

# Debian/Ubuntu
sudo apt-get install -y build-essential cmake ninja-build ccache libboost-all-dev
```

From the repository root:

```bash
cmake -S solidity -B solidity/build -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
cmake --build solidity/build --target solc \
      -j "$(nproc 2>/dev/null || sysctl -n hw.ncpu)"
```

The binary lands at `solidity/build/solc/solc`. Verify the tooling-fixture builtins before
using its output:

```bash
cat > /tmp/frame-probe.sol <<'EOF'
contract T {
    function approve() external { assembly { approvetx(0, 0, 3) } }
    function traceCount() external view returns (uint256 n) { assembly { n := txtrace(0, 0) } }
    function setDelegate(bytes32 salt, address target) external returns (address location) {
        assembly { location := setdelegate(salt, target) }
    }
    function setSelfDelegate(address target) external returns (bool success) {
        assembly { success := setselfdelegate(target) }
    }
}
EOF
solidity/build/solc/solc --experimental --evm-version @future \
    --bin /tmp/frame-probe.sol
rm -f /tmp/frame-probe.sol
```

Successful compilation identifies the current tooling compiler. A missing `approvetx`
identifies stock solc; a missing `txtrace`, `setdelegate`, or `setselfdelegate` can identify an
older submodule state.

## 2. Build Foundry against the patched revm and compilers

Foundry's manifest and lockfile pin all twelve REVM crates and the foundry-core compilers
fork (which adds the `@future` EVM version) to the current revisions. Foundry commit
`ffe76454940945b3b8ae6c7a6a0ae2939b4ff126` targets revm
`cad0e9fc012f790719791ff274b76eb852689559` and foundry-core
`f415f6fef0a62f44c7faa83daa8e37b14f0e009b`; all three commits are pushed and resolve from a
clean recursive clone:

```bash
cd ../foundry
cargo build --locked --bin forge --bin anvil
# Optional release binary:
cargo build --locked --bin forge --bin anvil --release
```

The binaries land under `foundry/target/{debug,release}/` as `forge` and `anvil`.

## 3. Run the contract tests

The patched forge compiles everything — policy, frame glue, accounts, EIP helpers —
natively: `contracts/foundry.toml` sets `evm_version = "@future"`, `experimental = true`,
and `solc = "../solidity/build/solc/solc"` in its default profile.

```bash
cd ../contracts
../foundry/target/debug/forge test --allow-local-compiler
# Or use the release binary:
../foundry/target/release/forge test --allow-local-compiler
```

Current Foundry requires `--allow-local-compiler` for an executable configured by path.
Use it only after building `solidity/build/solc/solc` from the pinned Solidity submodule.

Stock Forge cannot build or execute these tests: its compilers reject `@future`, its revm
treats `0xaa` and `0xb0`-`0xb9` as invalid opcodes, and it lacks the frame-context
cheatcodes. The `policy` profile (`FOUNDRY_PROFILE=policy`) remains stock-compatible for
the policy layer alone.

## Why `--experimental --evm-version @future`

The Frame profile, EIP-7819, EIP-7851, and EIP-8151 have no assigned compiler hard fork, so
their compiler behavior is gated behind solc's existing experimental `@future` EVM version.
`@future` always requires `--experimental`. Without those flags, the opcode names remain
available as ordinary identifiers and high-level `ecrecover` remains `pure`; at `@future`,
EIP-8151 makes it `view`. Anvil separately requires `--enable-eip7819`, `--enable-eip7851`, or
`--enable-eip8151` and Prague-or-later rules; selecting `@future` in solc does not activate the
node. EIP-7851's upstream opcode is still TBD, so this toolkit provisionally and
non-normatively uses `0xf7`.

## Optional solc tests

From the repository root:

```bash
cmake --build solidity/build --target isoltest -j 8
solidity/build/test/tools/isoltest --testpath solidity/test \
    --no-semantic-tests --no-smt --no-color < /dev/null
```

Semantic tests need `libevmone`, which is not required by the toolkit. To run only the
frame-opcode syntax tests under `@future`:

```bash
solidity/build/test/tools/isoltest --testpath solidity/test \
    --no-semantic-tests --no-smt --no-color --evm-version @future \
    -t "syntaxTests/inlineAssembly/frame_transaction*" < /dev/null
```

EIP-8151's SMT fixtures require a build with Z3 or cvc5. They are skipped rather than treated
as passing when no solver is configured.
