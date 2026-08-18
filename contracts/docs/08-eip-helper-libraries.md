# 08 — EIP helper libraries

Typed `internal` libraries under [`src/eips/`](../src/eips/) for the roadmap EIPs whose
surface is worth wrapping. Everything inlines; nothing needs linking.

| Library | EIP | Compiles with | Executes on |
|---|---|---|---|
| [`Create2FactoryLib`](../src/eips/Create2FactoryLib.sol) | [7997](https://forkcast.org/eips/7997) — deterministic CREATE2 factory | stock solc | any chain with the factory; Anvil and Foundry's test EVM carry it by default |
| [`SetDelegateLib`](../src/eips/SetDelegateLib.sol) | [7819](https://forkcast.org/eips/7819) — `SETDELEGATE` | patched solc (`@future`) | Anvil `--enable-eip7819`; `computeDelegateAddress` runs anywhere |
| [`SelfDelegateLib`](../src/eips/SelfDelegateLib.sol) | [7851](https://forkcast.org/eips/7851) — `SETSELFDELEGATE` | patched solc (`@future`) | Anvil `--enable-eip7851`; the designator read helpers run anywhere |

EIP-8151 gets no library: it changes `ecrecover`'s protocol behavior (account-code
restriction) without adding anything callable to wrap.

## Create2FactoryLib

```solidity
import {Create2FactoryLib} from "../src/eips/Create2FactoryLib.sol";

bytes memory initCode = abi.encodePacked(type(MyAccount).creationCode, args);
address predicted = Create2FactoryLib.computeAddress(salt, keccak256(initCode));
address deployed  = Create2FactoryLib.deploy(salt, initCode);   // reverts DeploymentFailed
```

The factory returns the created address as exactly 20 unpadded bytes and reverts with
empty data on failure; the library decodes the former and surfaces the latter as
`DeploymentFailed`.

## SetDelegateLib

```solidity
address location = SetDelegateLib.setDelegate(salt, implementation); // 0xef0100 ++ impl
SetDelegateLib.clearDelegate(salt);                                  // zero target clears
address predicted = SetDelegateLib.computeDelegateAddress(factory, salt);
```

The location is `keccak256(0xef0100 ++ caller ++ salt)[12:]`, so only the creating
factory can update or clear an indicator.

## SelfDelegateLib

```solidity
bool ok = SelfDelegateLib.setSelfDelegate(newImpl);      // rewrites own code to 0xef0101 ++ newImpl
(bool isDelegation, bool ecdsaDisabled, address target) = SelfDelegateLib.delegation(account);
```

`setSelfDelegate` succeeds only from an account whose raw code is already a 23-byte
`0xef0100`/`0xef0101` indicator; the first success permanently disables residual ECDSA
authority. The read helpers parse the raw designator that `EXTCODECOPY` exposes.

## Tests

`test/Create2FactoryLib.t.sol` runs under stock Foundry. The other two harnesses are
built by `script/build-frame-accounts.sh` and etched like the frame accounts; their
opcode wrappers are asserted to halt while the enabling bit is off (this test EVM never
sets it), and their pure/view helpers are exercised for real, including a golden vector
for the EIP-7819 address derivation.
