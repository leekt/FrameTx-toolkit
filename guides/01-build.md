# Building the toolkit

The stack has three source components: patched **solc**, patched **revm**, and **Foundry**
built against that revm. solc produces the account artifacts; the patched Forge executes
them. Artifact generation must happen before `forge test`.

## Reproducibility

The root gitlinks, Foundry's twelve REVM manifest patches, and `Cargo.lock` record the exact
published commits in [VERSIONS.md](../VERSIONS.md). Follow the build order below from a fresh
clone.

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
fork (which adds the `@future` EVM version) to the published toolkit revisions:

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
../foundry/target/debug/forge test
# Or use the release binary:
../foundry/target/release/forge test
```

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
