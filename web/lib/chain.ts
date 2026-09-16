import {
  createPublicClient,
  http,
  isAddress,
  zeroAddress,
  type Address,
} from 'viem';
import { sepolia } from 'viem/chains';
import {
  QUOTER,
  USDC,
  WETH,
  quoterAbi,
  outputBeforeSlippage,
  reimbursementFees,
  reimbursementCeiling,
  gasSwapMinimum,
} from './frames';
export const rpcUrl =
  process.env.NEXT_PUBLIC_SEPOLIA_RPC_URL ||
  'https://ethereum-sepolia-rpc.publicnode.com';
export const client = createPublicClient({
  chain: sepolia,
  transport: http(rpcUrl, { timeout: 20000, retryCount: 1 }),
});
function configured(value: string | undefined): Address | undefined {
  return value && isAddress(value) && value !== zeroAddress ? value : undefined;
}
export const entryPoint = configured(process.env.NEXT_PUBLIC_VFRAME_ADDRESS);
export const factory = configured(process.env.NEXT_PUBLIC_FACTORY_ADDRESS);
export type Quote = {
  amount: bigint;
  output: bigint;
  minimum: bigint;
  fee: number;
  block: bigint;
  timestamp: number;
};
export async function quoteSwap(
  amount: bigint,
  slippageBps: number,
  blockNumber?: bigint,
): Promise<Quote> {
  if (amount <= 0n) throw new Error('Enter a positive USDC amount.');
  outputBeforeSlippage(0n, slippageBps);
  const block = blockNumber ?? (await client.getBlockNumber());
  const quotes = await Promise.allSettled(
    [100, 500, 3000, 10000].map(async (fee) => {
      const { result } = await client.simulateContract({
        address: QUOTER,
        abi: quoterAbi,
        functionName: 'quoteExactInputSingle',
        args: [
          {
            tokenIn: USDC,
            tokenOut: WETH,
            amountIn: amount,
            fee,
            sqrtPriceLimitX96: 0n,
          },
        ],
        blockNumber: block,
      });
      return { fee, output: result[0] };
    }),
  );
  const valid = quotes
    .flatMap((q) =>
      q.status === 'fulfilled' && q.value.output > 0n ? [q.value] : [],
    )
    .sort((a, b) => (a.output > b.output ? -1 : 1));
  if (!valid.length)
    throw new Error(
      'No direct USDC/WETH route could be quoted. Check the RPC or try a smaller amount.',
    );
  const best = valid[0],
    minimum = (best.output * BigInt(10000 - slippageBps)) / 10000n;
  if (minimum === 0n) throw new Error('The quoted output is too small.');
  return { amount, ...best, minimum, block, timestamp: Date.now() };
}

export async function quoteGasSwap(
  requiredMinimum: bigint,
  slippageBps: number,
  blockNumber?: bigint,
): Promise<Quote> {
  // Keep a small demonstration swap when existing ETH already covers gas and margin.
  if (requiredMinimum === 0n)
    return quoteSwap(1000000n, slippageBps, blockNumber);
  const output = outputBeforeSlippage(requiredMinimum, slippageBps);
  const block = blockNumber ?? (await client.getBlockNumber());
  const routes = await Promise.allSettled(
    [100, 500, 3000, 10000].map(async (fee) => {
      const { result } = await client.simulateContract({
        address: QUOTER,
        abi: quoterAbi,
        functionName: 'quoteExactOutputSingle',
        args: [
          {
            tokenIn: USDC,
            tokenOut: WETH,
            amount: output,
            fee,
            sqrtPriceLimitX96: 0n,
          },
        ],
        blockNumber: block,
      });
      return result[0];
    }),
  );
  const inputs = routes
    .flatMap((route) =>
      route.status === 'fulfilled' && route.value > 0n ? [route.value] : [],
    )
    .sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
  for (const input of new Set(inputs)) {
    // Confirm the actual exact-input call at the same block; do not extrapolate a unit price.
    const quote = await quoteSwap(input + 1n, slippageBps, block).catch(
      () => undefined,
    );
    if (quote && quote.minimum >= requiredMinimum) return quote;
  }
  throw new Error(
    'Could not quote enough ETH for the gas reservation and 25% margin. Check the RPC, fund the account with ETH, or lower the gas budgets.',
  );
}

export async function quoteAffordableGasSwap(p: {
  networkFees: { maxFeePerGas: bigint; maxPriorityFeePerGas: bigint };
  gasLimit: bigint;
  eth: bigint;
  deposit: bigint;
  usdc: bigint;
  slippageBps: number;
  priceOverride?: bigint;
  priorityAllowance?: bigint;
}) {
  if (p.usdc <= 0n)
    throw new Error(
      'The account needs USDC for this swap. The connected EOA will not top up its gas deposit.',
    );
  const availableQuote = await quoteSwap(p.usdc, p.slippageBps);
  const fees = reimbursementFees(
    p.networkFees,
    p.gasLimit,
    p.eth + p.deposit + availableQuote.minimum,
    p.priceOverride,
    p.priorityAllowance,
  );
  const requiredMinimum = gasSwapMinimum(
    p.gasLimit * reimbursementCeiling(fees),
    p.eth,
    p.deposit,
  );
  let quote = availableQuote;
  if (requiredMinimum === 0n) {
    quote = await quoteSwap(
      p.usdc < 1000000n ? p.usdc : 1000000n,
      p.slippageBps,
      availableQuote.block,
    );
  } else {
    const smaller = await quoteGasSwap(
      requiredMinimum,
      p.slippageBps,
      availableQuote.block,
    );
    // Rounding at the USDC's six-decimal boundary must not overspend the actual balance.
    if (smaller.amount <= p.usdc) quote = smaller;
  }
  if (quote.minimum < requiredMinimum)
    throw new Error(
      'The swap no longer covers the selected vFrame fee. Refresh the quote.',
    );
  return { quote, fees };
}
