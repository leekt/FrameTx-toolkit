# vFrame playground

A Sepolia frame editor with drag-and-drop, keyboard reordering, editable calldata and gas,
wallet signing, simulation, and on-chain frame receipts. Built with React, vinext, Cloudflare
Kumo, viem, and dnd-kit. The standalone app is in `web/`; contracts remain in `vframe/`.

## Deploy and configure

Fund the existing Foundry keystore account `ZERODEV_DEPLOYER` with Sepolia ETH, then run
from the repository root:

```bash
export SEPOLIA_RPC_URL=https://ethereum-sepolia-rpc.publicnode.com
forge script --root vframe vframe/script/DeployVFrame.s.sol:DeployVFrame \
  --rpc-url "$SEPOLIA_RPC_URL" --account ZERODEV_DEPLOYER --broadcast --slow
cd web
npm ci
npm run dev
```

Foundry unlocks the keystore interactively. Both contracts deploy through the standard
CREATE2 proxy (`0x4e59b44847b379578588920cA78FbF26c0B4956C`) with fixed salts, so changing
the deployer wallet or its nonce does not change their addresses. Reruns reuse existing
deployments. Code, salts and compiler settings still affect the addresses; see the
[deployment details](../vframe/README.md#sepolia-deployment-and-web-playground).

The deployment command calculates both addresses and writes them to `.env.local` before
broadcasting, preserving other settings. Dry runs also write the addresses; remove
`--broadcast` to configure the demo before deployment. On-chain execution requires the
contracts to be deployed. The script updates only these keys:

- `NEXT_PUBLIC_VFRAME_ADDRESS`
- `NEXT_PUBLIC_FACTORY_ADDRESS`

`NEXT_PUBLIC_SEPOLIA_RPC_URL` optionally overrides the public browser RPC. Do not put private
provider credentials in a `NEXT_PUBLIC_` variable. Restart the dev server or rebuild after
changing environment variables. Without deployment addresses the frame editor works, and
chain execution clearly remains disabled.

### Publish the web demo

The production demo is hosted at **https://vframes.taek.tech** with Cloudflare Workers
Static Assets. After deploying the contracts, rebuild and publish using the existing
Wrangler login:

```bash
npm run deploy --prefix web
```

`wrangler.static.jsonc` binds that exact hostname as a Workers Custom Domain. Cloudflare manages
its DNS record and TLS certificate. Only `dist/client` is uploaded; local environment
files, private keys and source files are excluded. The separate Tailscale preview remains
available for local development.

## USDC → ETH → spend

1. Connect a browser wallet on Ethereum Sepolia. The factory predicts its account address.
2. Get official Ethereum Sepolia USDC from [Circle’s faucet](https://faucet.circle.com/).
3. Choose **Swap & spend ETH** under **Sequences** to fill the editor and quote available
   direct Uniswap v3 USDC/WETH fee tiers. **Swap settings** lets you change the USDC amount,
   ETH recipient, and slippage; **Update sequence** applies those changes.
4. Fund the predicted account with USDC and enough Sepolia ETH for the displayed maximum
   gas reservation. You can fund it before deployment. The wallet also needs ETH for outer gas.
5. Reorder or edit the frames. Click **Approve Pay**, **Approve Execution**, or **Atomic** on a frame
   to toggle its flags; selected controls show a checkmark. Atomic links the frame to the
   next one. Click **Sign, simulate & submit** once. The wallet signs the actual sequence,
   the app simulates it, and then the wallet confirms the outer transaction. A failed or
   rolled-back simulated frame stops submission.
6. Inspect vFrame’s emitted receipts after mining. The relayer can withdraw its reimbursement
   credit afterward. The EOA may pay more network gas than the account reimburses; the demo
   shows that warning and lets the EOA proceed, without topping up the account's gas deposit.

The preset has six frames:

| Mode    | Call                                                  |
| ------- | ----------------------------------------------------- |
| DEFAULT | Idempotent `factory.createAccount(owner, salt)`       |
| VERIFY  | Account validation and missing gas-deposit prefunding |
| SENDER  | Approve the exact USDC input                          |
| SENDER  | Swap USDC to WETH, sending output to the router       |
| SENDER  | Unwrap the router’s WETH into account ETH             |
| SENDER  | Spend the guaranteed minimum ETH output               |

The last four frames form an atomic group. Swap output above the signed minimum stays in
the account as ETH. Validation happens before the swap, so its fee reservation cannot use
future swap proceeds. Quotes are testnet liquidity quotes, not market-price estimates.
If a route dries up, quoting or simulation fails instead of showing a fabricated exchange.
Changing swap inputs requires rebuilding the preset. After building, the editable frame
calldata is authoritative. Any frame edit, reordering, wallet change, or settings change
invalidates a prepared signature. Signatures expire after ten minutes.

## Pay for the transaction after swapping

Select **Test pay for tx after swap** to fill the editor with:

| Mode    | Call                                                   |
| ------- | ------------------------------------------------------ |
| DEFAULT | Deploy the account if needed                           |
| VERIFY  | Authorize execution through the sender (flags `2`)     |
| SENDER  | Approve the USDC input                                 |
| SENDER  | Swap USDC to WETH                                      |
| SENDER  | Unwrap WETH into account ETH                           |
| VERIFY  | Approve payment and fund gas from that ETH (flags `1`) |

There are two VERIFY frames. The first checks the owner's signed transaction and grants
execution authority before any SENDER call, without reserving gas payment. The final VERIFY
approves payment from the swap output. Both call the account's `validateFrame` with different
approval flags.
Approve, swap, and unwrap form an atomic group; the group ends before payment validation.
The account can start with USDC and zero ETH or gas deposit. The preset quotes the available
USDC across direct Uniswap fee tiers and automatically lowers the virtual reimbursement
price to fit the account's funds with a **25% margin after slippage**. The swap never exceeds
the USDC balance. Existing ETH and deposits count toward coverage. If a smaller swap covers
the reservation, it uses that amount; when no swap proceeds are needed for gas, it swaps up
to 1 USDC as a demonstration. Remaining ETH and unused deposit stay with the account.

vFrame reserves `totalGasLimit × (maxFeePerGas + maxPriorityFeePerGas)` and charges the
network base fee clamped between `maxFeePerGas` and that sum. Auto selects an affordable
fixed rate (zero priority allowance). The controls allow a custom floor and allowance.
The EOA's outer transaction uses separate network fee settings; its effective price does
not change vFrame's reimbursement. A lower virtual price is allowed with a warning that
the EOA covers the difference. It never automatically funds the account's gas deposit.

Measured preset budgets total **1,650,000 gas for a new account** and **675,000 for an
existing account**, versus 2,490,000 previously. The idempotent factory call drops from
1,000,000 to 25,000 once the account is deployed. Explicit custom gas limits are preserved.
These budgets were verified on Sepolia forks with cold accesses, including a 20-USDC,
zero-ETH account at an affordable price below the network base fee.

This fee model requires the updated vFrame deployment. The UI checks `getGasQuote` against
the signed range before requesting a signature and reports an older deployment explicitly.
Changing the EntryPoint changes the deterministic factory/account addresses; funds in an
older account stay there.

Selecting either preset before connecting a wallet fills its frame template. After connecting,
**Sign, simulate & submit** automatically quotes and prepares an unprepared preset. The pay-after-swap
preset refreshes fees, balances, and its swap quote before every signature, using the same fee
cap for sizing and signing. It preserves frame ordering, approval flags and gas budgets.
Editing a call's mode, target, value or calldata, or adding/removing a frame, makes the sequence
custom and stops automatic replacement of call data. The calculated swap amount is shown
beside **Swap settings**. The margin covers funding headroom; slippage limits and full
simulation still reject an unavailable route or invalid sequence.
Simulation checks funding at the actual payment frame, so it permits payment from earlier
swap proceeds. Moving payment before the swap fails when the account has no starting ETH.

## Verified network constants

- [Circle’s USDC list](https://developers.circle.com/stablecoins/usdc-contract-addresses):
  `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` (6 decimals).
- [Uniswap’s Sepolia deployment table](https://developers.uniswap.org/docs/protocols/v3/deployments/v3-ethereum-deployments):
  WETH `0xfff9976782d46cc05630d1f6ebab18b2324d6b14`, SwapRouter02
  `0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E`, QuoterV2
  `0xEd1f6473345F45b75F8179591dd5bA1888cf2FB3`.

## Development and checks

```bash
# Root
forge build --root vframe
node web/scripts/sync-abi.mjs
forge test --root vframe
SEPOLIA_FORK_RPC_URL=https://ethereum-sepolia-rpc.publicnode.com \
  forge test --root vframe --match-contract VFrameSepoliaTest -vv
# web/
npm run typecheck
npm test
npm run build
```

`npm test` starts and stops its own loopback-only stock Osaka Anvil node. It compares the
browser’s EIP-712 hash to the contract, verifies reordered frames invalidate the signature,
and mines a signed operation deploying, validating, prefunding, and spending from an account.
The optional Sepolia fork tests use actual Circle USDC and Uniswap code and state, with
local-only test funding; they never broadcast to Sepolia. They cover the full swap and spend,
atomic rollback when swapping before approval, payment after swapping with zero starting
account ETH, and rejection when payment is moved before that swap.
The frontend ABI files are generated from stock Forge artifacts and checked in.

The app exposes optional `read_frame_sequence` and `reorder_frames` WebMCP tools on browsers
that support `document.modelContext`. They cannot sign or submit transactions. Browser WebMCP
runtime verification has not been performed in this environment.

## Tailnet preview

Development binds to `127.0.0.1:4181`. The configured exact allowed host is
`leekt-macmini.tail45c85e.ts.net`; change it for another machine. The current machine can
forward this port within its tailnet:

```bash
/Applications/Tailscale.app/Contents/MacOS/Tailscale serve --bg --tcp=4181 tcp://127.0.0.1:4181
```

Open `http://leekt-macmini.tail45c85e.ts.net:4181/`. If your wallet requires a secure origin,
use the loopback URL on the development machine or configure tailnet HTTPS in Tailscale.
The server rejects unlisted hostnames and denies `.env`, keys, and Git paths. This does not
publish the app to the public internet. `npm run build` produces a static export in `dist/client/`.

For the static server, run `npm run build && npm start`. It binds to loopback on the same
port; stop the development server first. `PORT` and `VFRAME_ALLOWED_HOST` allow an explicit
port and MagicDNS hostname on another machine. Rebuilding updates the static preview without
a server restart; refresh the browser after deployment or configuration changes.
