import {
  encodeFunctionData,
  encodeAbiParameters,
  parseAbi,
  parseUnits,
  zeroAddress,
  zeroHash,
  hashTypedData,
  concatHex,
  sliceHex,
  toHex,
  isAddress,
  type Address,
  type Hex,
} from 'viem';
import { factoryAbi } from './factoryAbi';
import { accountAbi } from './accountAbi';

// Circle and Uniswap's official Ethereum Sepolia deployments (links in README).
export const USDC = '0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238' as const;
export const WETH = '0xfff9976782d46cc05630d1f6ebab18b2324d6b14' as const;
export const ROUTER = '0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E' as const;
export const QUOTER = '0xEd1f6473345F45b75F8179591dd5bA1888cf2FB3' as const;
export const SALT = zeroHash;
export const DEFAULT_OVERHEAD_GAS = '250000';
export const tokenAbi = parseAbi([
  'function approve(address spender,uint256 value) returns(bool)',
  'function transfer(address to,uint256 amount) returns(bool)',
  'function balanceOf(address account) view returns(uint256)',
]);
export const routerAbi = parseAbi([
  'function exactInputSingle((address tokenIn,address tokenOut,uint24 fee,address recipient,uint256 amountIn,uint256 amountOutMinimum,uint160 sqrtPriceLimitX96) params) payable returns(uint256 amountOut)',
  'function unwrapWETH9(uint256 amountMinimum,address recipient) payable',
]);
export const quoterAbi = parseAbi([
  'function quoteExactInputSingle((address tokenIn,address tokenOut,uint256 amountIn,uint24 fee,uint160 sqrtPriceLimitX96) params) returns(uint256 amountOut,uint160 sqrtPriceX96After,uint32 initializedTicksCrossed,uint256 gasEstimate)',
  'function quoteExactOutputSingle((address tokenIn,address tokenOut,uint256 amount,uint24 fee,uint160 sqrtPriceLimitX96) params) returns(uint256 amountIn,uint160 sqrtPriceX96After,uint32 initializedTicksCrossed,uint256 gasEstimate)',
]);
export type Frame = {
  mode: number;
  flags: number;
  target: Address;
  gasLimit: bigint;
  value: bigint;
  data: Hex;
};
export type Signature = {
  scheme: number;
  signer: Address;
  message: Hex;
  signature: Hex;
};
export type Transaction = {
  sender: Address;
  nonceKeys: bigint[];
  nonce: bigint;
  validUntil: number;
  overheadGasLimit: bigint;
  maxFeePerGas: bigint;
  maxPriorityFeePerGas: bigint;
  frames: Frame[];
  signatures: Signature[];
};
export type Draft = {
  id: string;
  title: string;
  description: string;
  mode: number;
  flags: number;
  target: string;
  gasLimit: string;
  value: string;
  data: string;
};
export type FrameResult = {
  status: number;
  rolledBack: boolean;
  returnData: Hex;
};
export const names = ['DEFAULT', 'VERIFY', 'SENDER'];
export type SequencePreset = 'swap-spend' | 'pay-after-swap';
let nextId = 0;
export const newId = () => `frame-${++nextId}`;
function draft(
  id: string,
  title: string,
  description: string,
  mode: number,
  flags: number,
  gasLimit: string,
): Draft {
  return {
    id,
    title,
    description,
    mode,
    flags,
    gasLimit,
    target: zeroAddress,
    value: '0',
    data: '0x',
  };
}
export function initialFrames(preset: SequencePreset = 'swap-spend'): Draft[] {
  const frames = [
    draft(
      'deploy',
      'Deploy account',
      'Create the account at its deterministic address.',
      0,
      0,
      '1000000',
    ),
    draft(
      'verify',
      'Validate & pay gas',
      'Check the signature and fund the gas deposit.',
      1,
      3,
      '65000',
    ),
    draft(
      'approve',
      'Approve USDC',
      'Approve only the USDC amount being swapped.',
      2,
      4,
      '60000',
    ),
    draft(
      'swap',
      'Swap USDC → WETH',
      'Exchange Circle faucet USDC on Uniswap v3.',
      2,
      4,
      '200000',
    ),
    draft(
      'unwrap',
      'Unwrap WETH → ETH',
      'Return the swap output to the account as native ETH.',
      2,
      4,
      '45000',
    ),
    draft(
      'spend',
      'Spend ETH',
      'Send the guaranteed ETH output to the recipient.',
      2,
      0,
      '40000',
    ),
  ];
  if (preset === 'pay-after-swap') {
    frames[1] = {
      ...frames[1],
      title: 'Authorize execution',
      description:
        'Verify the owner signature and approve SENDER calls without paying gas yet.',
      flags: 2,
      gasLimit: '30000',
    };
    // The swap group ends before the separate payment VERIFY frame.
    frames[4].flags = 0;
    frames[5] = draft(
      'pay',
      'Pay gas from swap',
      'Use the ETH received from the swap to fund the gas reservation.',
      1,
      1,
      '65000',
    );
  }
  return frames;
}
export function customFrame(mode: number): Draft {
  const f = draft(
    newId(),
    `${names[mode]} call`,
    'Custom calldata and call budget.',
    mode,
    mode === 1 ? 3 : 0,
    '250000',
  );
  if (mode === 1)
    f.data = encodeFunctionData({
      abi: accountAbi,
      functionName: 'validateFrame',
      args: ['0x'],
    });
  return f;
}
export function makeSwapFrames(p: {
  owner: Address;
  sender: Address;
  factory: Address;
  recipient: Address;
  amount: bigint;
  minimum: bigint;
  fee: number;
  preset?: SequencePreset;
}): Draft[] {
  if (p.amount <= 0n || p.minimum <= 0n)
    throw new Error('Swap amount and minimum output must be positive.');
  const f = initialFrames(p.preset);
  f[0].target = p.factory;
  f[0].data = encodeFunctionData({
    abi: factoryAbi,
    functionName: 'createAccount',
    args: [p.owner, SALT],
  });
  f[1].data = encodeFunctionData({
    abi: accountAbi,
    functionName: 'validateFrame',
    args: [encodeAbiParameters([{ type: 'uint256' }], [0n])],
  });
  f[2].target = USDC;
  f[2].data = encodeFunctionData({
    abi: tokenAbi,
    functionName: 'approve',
    args: [ROUTER, p.amount],
  });
  f[3].target = ROUTER;
  f[3].data = encodeFunctionData({
    abi: routerAbi,
    functionName: 'exactInputSingle',
    args: [
      {
        tokenIn: USDC,
        tokenOut: WETH,
        fee: p.fee,
        recipient: ROUTER,
        amountIn: p.amount,
        amountOutMinimum: p.minimum,
        sqrtPriceLimitX96: 0n,
      },
    ],
  });
  f[4].target = ROUTER;
  f[4].data = encodeFunctionData({
    abi: routerAbi,
    functionName: 'unwrapWETH9',
    args: [p.minimum, p.sender],
  });
  if (p.preset === 'pay-after-swap') {
    f[5].data = encodeFunctionData({
      abi: accountAbi,
      functionName: 'validateFrame',
      args: [encodeAbiParameters([{ type: 'uint256' }], [0n])],
    });
  } else {
    f[5].target = p.recipient;
    f[5].value = formatDecimal(p.minimum, 18);
  }
  return f;
}
export function formatDecimal(value: bigint, decimals: number): string {
  const factor = 10n ** BigInt(decimals);
  const fraction = (value % factor)
    .toString()
    .padStart(decimals, '0')
    .replace(/0+$/, '');
  return `${value / factor}${fraction ? '.' + fraction : ''}`;
}
export function decimal(value: string, decimals: number): bigint {
  if (!new RegExp(`^\\d+(?:\\.\\d{1,${decimals}})?$`).test(value))
    throw new Error(
      `Use a positive decimal with at most ${decimals} decimal places.`,
    );
  return parseUnits(value, decimals);
}
export function encodeFrames(drafts: Draft[]): Frame[] {
  if (!drafts.length || drafts.length > 64)
    throw new Error('An operation needs 1–64 frames.');
  return drafts.map((f, i) => {
    if (!isAddress(f.target))
      throw new Error(`Frame ${i}: enter a valid target address.`);
    if (!/^0x(?:[\da-fA-F]{2})*$/.test(f.data))
      throw new Error(`Frame ${i}: calldata must be even-length hex.`);
    if (!/^\d+$/.test(f.gasLimit))
      throw new Error(`Frame ${i}: gas must be a positive integer.`);
    const gas = BigInt(f.gasLimit);
    if (gas <= 0n || gas > 10000000n)
      throw new Error(`Frame ${i}: gas must be between 1 and 10,000,000.`);
    if (
      ![0, 1, 2].includes(f.mode) ||
      !Number.isInteger(f.flags) ||
      f.flags < 0 ||
      f.flags > 7
    )
      throw new Error(`Frame ${i}: invalid mode or flags.`);
    const value = decimal(f.value, 18);
    if (f.mode !== 2 && value !== 0n)
      throw new Error(`Frame ${i}: only SENDER frames can transfer ETH.`);
    return {
      mode: f.mode,
      flags: f.flags,
      target: f.target as Address,
      gasLimit: gas,
      value,
      data: f.data as Hex,
    };
  });
}
export const types = {
  Frame: [
    { name: 'mode', type: 'uint8' },
    { name: 'flags', type: 'uint8' },
    { name: 'target', type: 'address' },
    { name: 'gasLimit', type: 'uint64' },
    { name: 'value', type: 'uint256' },
    { name: 'data', type: 'bytes' },
  ],
  Signature: [
    { name: 'scheme', type: 'uint8' },
    { name: 'signer', type: 'address' },
    { name: 'message', type: 'bytes32' },
    { name: 'signature', type: 'bytes' },
  ],
  Transaction: [
    { name: 'sender', type: 'address' },
    { name: 'nonceKeys', type: 'uint256[]' },
    { name: 'nonce', type: 'uint64' },
    { name: 'validUntil', type: 'uint48' },
    { name: 'overheadGasLimit', type: 'uint64' },
    { name: 'maxFeePerGas', type: 'uint256' },
    { name: 'maxPriorityFeePerGas', type: 'uint256' },
    { name: 'frames', type: 'Frame[]' },
    { name: 'signatures', type: 'Signature[]' },
  ],
} as const;
export function typedData(ep: Address, t: Transaction) {
  return {
    domain: {
      name: 'vFrame',
      version: '2',
      chainId: 11155111,
      verifyingContract: ep,
    },
    types,
    primaryType: 'Transaction' as const,
    message: {
      ...t,
      signatures: t.signatures.map((s) => ({
        ...s,
        signature: s.message === zeroHash ? ('0x' as Hex) : s.signature,
      })),
    },
  };
}
export const transactionHash = (ep: Address, t: Transaction) =>
  hashTypedData(typedData(ep, t));
export function frameSignature(walletSignature: Hex): Hex {
  if (walletSignature.length !== 132)
    throw new Error('Expected a 65-byte wallet signature.');
  const v = Number(BigInt(sliceHex(walletSignature, 64, 65)));
  const parity = v >= 27 ? v - 27 : v;
  if (parity !== 0 && parity !== 1)
    throw new Error('Invalid signature recovery byte.');
  return concatHex([
    toHex(parity, { size: 1 }),
    sliceHex(walletSignature, 0, 64),
  ]);
}
export function outerGas(t: Transaction): bigint {
  const total =
    t.overheadGasLimit + t.frames.reduce((sum, f) => sum + f.gasLimit, 0n);
  if (total > 16000000n)
    throw new Error(
      'Lower the total gas budget to leave room for outer transaction overhead.',
    );
  // Includes intrinsic calldata gas and EIP-150 forwarding headroom.
  return total + total / 32n + 200000n;
}
export function statusText(result: FrameResult): string {
  if (result.status === 2) return 'Skipped';
  if (result.rolledBack)
    return result.status === 0
      ? 'Failed · group rolled back'
      : 'Returned · rolled back';
  return result.status === 1 ? 'Succeeded' : 'Failed';
}

export function gasReservation(
  frames: Draft[],
  overhead: string,
  price: bigint | undefined,
): bigint | undefined {
  if (price === undefined || !/^\d+$/.test(overhead)) return undefined;
  try {
    return (
      (BigInt(overhead) +
        encodeFrames(frames).reduce((sum, frame) => sum + frame.gasLimit, 0n)) *
      price
    );
  } catch {
    return undefined;
  }
}

// Round up so tiny amounts receive the same minimum 25% margin.
export const bufferedGasCost = (maxCost: bigint) =>
  (maxCost * 12500n + 9999n) / 10000n;

export function affordableGasPrice(
  gasLimit: bigint,
  available: bigint,
): bigint {
  if (gasLimit <= 0n || available < 0n)
    throw new Error('Invalid gas budget or balance.');
  return (available * 10000n) / (gasLimit * 12500n);
}

export function reimbursementFees(
  network: { maxFeePerGas: bigint; maxPriorityFeePerGas: bigint },
  gasLimit: bigint,
  available: bigint,
  override?: bigint,
  priorityAllowance = 0n,
) {
  const affordable = affordableGasPrice(gasLimit, available);
  const automaticUpper =
    affordable < network.maxFeePerGas ? affordable : network.maxFeePerGas;
  const maxFeePerGas = override ?? automaticUpper - priorityAllowance;
  if (maxFeePerGas < 0n) throw new Error('Gas price cannot be negative.');
  if (priorityAllowance < 0n || maxFeePerGas + priorityAllowance > affordable)
    throw new Error(
      'This vFrame price range exceeds the account balance with a 25% margin. Use Auto or lower the prices.',
    );
  return {
    maxFeePerGas,
    maxPriorityFeePerGas: priorityAllowance,
  };
}

export const reimbursementCeiling = (fees: {
  maxFeePerGas: bigint;
  maxPriorityFeePerGas: bigint;
}) => fees.maxFeePerGas + fees.maxPriorityFeePerGas;

export function reimbursementPrice(
  baseFee: bigint,
  fees: { maxFeePerGas: bigint; maxPriorityFeePerGas: bigint },
): bigint {
  const upper = reimbursementCeiling(fees);
  return baseFee < fees.maxFeePerGas
    ? fees.maxFeePerGas
    : baseFee > upper
      ? upper
      : baseFee;
}

export function gasSwapMinimum(
  maxCost: bigint,
  accountETH: bigint,
  deposit: bigint,
): bigint {
  const missing = bufferedGasCost(maxCost) - accountETH - deposit;
  return missing > 0n ? missing : 0n;
}

export function outputBeforeSlippage(
  minimum: bigint,
  slippageBps: number,
): bigint {
  if (!Number.isInteger(slippageBps) || slippageBps < 1 || slippageBps > 500)
    throw new Error('Slippage must be 0.01%–5%.');
  const remaining = BigInt(10000 - slippageBps);
  return (minimum * 10000n + remaining - 1n) / remaining;
}

// Refresh generated calls while retaining edited flags, gas limits and frame order.
// Custom calldata/target/value edits turn the sequence into a custom one instead.
export function refillSwapFrames(drafts: Draft[], generated: Draft[]): Draft[] {
  return drafts.map((frame) => {
    const filled = generated.find((candidate) => candidate.id === frame.id);
    return filled
      ? {
          ...frame,
          target: filled.target,
          value: filled.value,
          data: filled.data,
        }
      : frame;
  });
}

// The factory is idempotent. Reserve code-deposit gas only for a new account.
// Other limits are explicit user overrides and remain unchanged.
export function accountDeploymentBudget(
  drafts: Draft[],
  deployed: boolean,
): Draft[] {
  return drafts.map((frame) =>
    frame.id === 'deploy' && ['1000000', '25000'].includes(frame.gasLimit)
      ? { ...frame, gasLimit: deployed ? '25000' : '1000000' }
      : frame,
  );
}
