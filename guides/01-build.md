# Building the toolkit

The repository pins four toolchain forks—patched **solc**, patched **revm**, patched
**foundry-core**, and **Foundry** built against the latter two. The contract project uses
Soldeer for **ZeroDev Kernel v3.3**, **Solady**, **forge-std**, and
**ExcessivelySafeCall**, with exact revisions in `contracts/soldeer.lock`.
Kernel is not a separate build product: solc produces the account artifacts, foundry-core
exposes the experimental compiler target, and patched Forge executes the artifacts. Artifact
generation must happen before `forge test`.

## Reproducibility

The root gitlinks, Foundry's twelve REVM manifest patches, `Cargo.lock`, and the contract
project's `soldeer.lock` record the exact current stack in [VERSIONS.md](../VERSIONS.md):

- Solidity `develop` is pinned at `4c6c547d9a35b23807f421692ac65c35f26f3d54`.
- revm `main` is pinned at `21ace0ade666d99f3e1c6e95ba173972164d0ceb`.
- foundry-core `main` is pinned at `f415f6fef0a62f44c7faa83daa8e37b14f0e009b`.
- Foundry `master` is pinned at `5683db7dc79cace93363fe3465e20792b859bec9`.
- The official Kernel v3.3 fixture is pinned at
  `cd697c7e21715d015e0643af22310a99aa17433b`.
- Solady is pinned at `3f2f5345261904463f5429c9031c3d2185c0f4fe`, the exact
  `0.0.278` revision used by that Kernel fixture.
- ExcessivelySafeCall is pinned at `81cd99ce3e69117d665d7601c330ea03b97acce0`,
  and forge-std is locked to registry release `1.16.2`.

The four toolchain forks publish EIP-8141 on their default branches. Foundry promotion passed
27/27 primitives, 44/44 Anvil unit, and 30/30 Anvil integration tests. The root gitlinks pin
those toolchain commits; `git submodule update --init --recursive` checks out the four
top-level toolchain submodules. Soldeer restores every Solidity dependency separately from
the contract lockfile. For toolchain update discovery, the repository's sync command fetches
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
`5683db7dc79cace93363fe3465e20792b859bec9` targets revm
`21ace0ade666d99f3e1c6e95ba173972164d0ceb` and foundry-core
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
../foundry/target/debug/forge soldeer install
../foundry/target/debug/forge test --allow-local-compiler
# Or use the release binary:
../foundry/target/release/forge soldeer install
../foundry/target/release/forge test --allow-local-compiler
```

The current project result is 304 passed, 0 failed, and 0 skipped across 17 suites. That
includes the Kernel v3.3 factory/proxy migration, the same-address EIP-7702 migration, all
three Frame account roles, both rollback paths, and sponsorship by all three example
paymasters.

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
