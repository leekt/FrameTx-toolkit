# 08 — EIP helper libraries

The supported deployment helper is `Create2FactoryLib` (EIP-7997). EIP-7819 and EIP-7851
were declined for Hegotá, so their libraries and opcode harnesses are removed. EIP-8298
is the selected code-reuse proposal, but its opcode is still TBD and has no library yet.
See [the current AA set](../../spec/README.md).

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

## Tests

`test/Create2FactoryLib.t.sol` exercises the existing deterministic factory with stock
opcodes. The deleted delegation helpers are no longer part of the contract suite.
