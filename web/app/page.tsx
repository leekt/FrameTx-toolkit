'use client';
import { useEffect, useRef, useState } from 'react';
import Link from 'next/link';
import { flushSync } from 'react-dom';
import { Button } from '@cloudflare/kumo/components/button';
import { Input } from '@cloudflare/kumo/components/input';
import {
  DndContext,
  closestCenter,
  KeyboardSensor,
  PointerSensor,
  useSensor,
  useSensors,
  type DragEndEvent,
} from '@dnd-kit/core';
import {
  SortableContext,
  useSortable,
  arrayMove,
  sortableKeyboardCoordinates,
  verticalListSortingStrategy,
} from '@dnd-kit/sortable';
import { CSS } from '@dnd-kit/utilities';
import {
  createWalletClient,
  BaseError,
  ContractFunctionRevertedError,
  custom,
  decodeFunctionResult,
  encodeFunctionData,
  formatEther,
  getContractError,
  isAddress,
  parseEventLogs,
  zeroHash,
  type Address,
  type Hex,
  type EIP1193Provider,
} from 'viem';
import { sepolia } from 'viem/chains';
import {
  client,
  entryPoint,
  factory,
  quoteSwap,
  quoteAffordableGasSwap,
  type Quote,
} from '../lib/chain';
import { vframeAbi } from '../lib/vframeAbi';
import { factoryAbi } from '../lib/factoryAbi';
import { accountAbi } from '../lib/accountAbi';
import {
  USDC,
  WETH,
  ROUTER,
  SALT,
  DEFAULT_OVERHEAD_GAS,
  tokenAbi,
  initialFrames,
  customFrame,
  makeSwapFrames,
  encodeFrames,
  decimal,
  formatDecimal,
  typedData,
  transactionHash,
  frameSignature,
  outerGas,
  statusText,
  gasReservation,
  bufferedGasCost,
  refillSwapFrames,
  accountDeploymentBudget,
  reimbursementFees,
  reimbursementCeiling,
  reimbursementPrice,
  names,
  type Draft,
  type Transaction,
  type FrameResult,
  type SequencePreset,
} from '../lib/frames';

type Provider = EIP1193Provider & {
  on?: (event: string, callback: (value: unknown) => void) => void;
  removeListener?: (event: string, callback: (value: unknown) => void) => void;
};
declare global {
  interface Window {
    ethereum?: Provider;
  }
}
const short = (address: string) =>
  `${address.slice(0, 6)}…${address.slice(-4)}`;
const errorText = (error: unknown) =>
  error instanceof Error ? error.message : String(error);
const explorer = (address: string) =>
  `https://sepolia.etherscan.io/address/${address}`;
const configReady = Boolean(entryPoint && factory);
type Balances = {
  eth: bigint;
  usdc: bigint;
  deposit: bigint;
  credit: bigint;
  deployed: boolean;
};
type Fees = { maxFeePerGas: bigint; maxPriorityFeePerGas: bigint };
type FundingSnapshot = { balances: Balances; fees: Fees };
type Prepared = { transaction: Transaction; revision: number };
const frameFlags = [
  {
    bit: 1,
    label: 'Approve Pay',
    description: 'Allow this frame to approve gas payment.',
  },
  {
    bit: 2,
    label: 'Approve Execution',
    description: 'Allow this frame to authorize later SENDER calls.',
  },
  {
    bit: 4,
    label: 'Atomic',
    description:
      'Link this frame to the next. If any frame in the group fails, the whole group rolls back.',
  },
];

function FrameRow({
  frame,
  index,
  count,
  disabled,
  update,
  remove,
  move,
}: {
  frame: Draft;
  index: number;
  count: number;
  disabled: boolean;
  update: (patch: Partial<Draft>) => void;
  remove: () => void;
  move: (direction: number) => void;
}) {
  const {
    attributes,
    listeners,
    setNodeRef,
    transform,
    transition,
    isDragging,
  } = useSortable({ id: frame.id, disabled });
  return (
    <li
      ref={setNodeRef}
      style={{ transform: CSS.Transform.toString(transform), transition }}
      className={`frame ${isDragging ? 'dragging' : ''}`}
      data-mode={frame.mode}
    >
      <Button
        variant="ghost"
        size="sm"
        className="handle"
        disabled={disabled}
        {...attributes}
        {...listeners}
        aria-label={`Move ${frame.title}`}
      >
        ⠿
      </Button>
      <div className="frame-content">
        <details className="frame-editor">
          <summary className="frame-summary">
            <span className="index">{String(index).padStart(2, '0')}</span>
            <span className="frame-separator" aria-hidden="true">
              /
            </span>
            <span className={`mode mode-${frame.mode}`}>
              {names[frame.mode]}
            </span>
            <span className="frame-separator" aria-hidden="true">
              /
            </span>
            <span className="frame-action">
              <span className="frame-name">{frame.title}</span>
            </span>
            <span className="frame-toggle" aria-hidden="true">
              Edit
            </span>
          </summary>
          <p className="frame-gas">
            {Number(frame.gasLimit).toLocaleString('en-US')} gas
          </p>
          <p className="frame-description">{frame.description}</p>
          <fieldset disabled={disabled} className="fields">
            <Input
              label="Label"
              value={frame.title}
              onChange={(e) => update({ title: e.target.value })}
            />
            <fieldset className="actions" aria-label="Frame mode">
              {names.map((name, mode) => (
                <Button
                  key={name}
                  size="sm"
                  variant={frame.mode === mode ? 'primary' : 'secondary'}
                  onClick={() => update({ mode })}
                >
                  {name}
                </Button>
              ))}
            </fieldset>
            <Input
              label="Target · zero resolves to your account"
              value={frame.target}
              onChange={(e) => update({ target: e.target.value })}
            />
            <Input
              label="Calldata · complete hex including selector"
              value={frame.data}
              onChange={(e) => update({ data: e.target.value })}
            />
            <div className="two">
              <Input
                label="Gas limit"
                inputMode="numeric"
                value={frame.gasLimit}
                onChange={(e) => update({ gasLimit: e.target.value })}
              />
              <Input
                label="ETH value"
                inputMode="decimal"
                value={frame.value}
                onChange={(e) => update({ value: e.target.value })}
              />
            </div>
          </fieldset>
        </details>
        <fieldset
          className="frame-flags"
          aria-label={`Frame ${index} flags`}
          disabled={disabled}
        >
          {frameFlags.map(({ bit, label, description }) => {
            const enabled = Boolean(frame.flags & bit);
            return (
              <Button
                key={bit}
                type="button"
                size="sm"
                variant={enabled ? 'primary' : 'secondary'}
                className="frame-flag"
                aria-pressed={enabled}
                title={description}
                disabled={disabled}
                onClick={() => update({ flags: frame.flags ^ bit })}
              >
                <span className="frame-flag-state" aria-hidden="true">
                  {enabled ? '✓' : '○'}
                </span>
                {label}
                {bit === 4 && <span aria-hidden="true">↓</span>}
              </Button>
            );
          })}
        </fieldset>
      </div>
      <div className="frame-tools">
        <Button
          variant="ghost"
          size="sm"
          disabled={disabled || index === 0}
          aria-label={`Move ${frame.title} up`}
          onClick={() => move(-1)}
        >
          ↑
        </Button>
        <Button
          variant="ghost"
          size="sm"
          disabled={disabled || index === count - 1}
          aria-label={`Move ${frame.title} down`}
          onClick={() => move(1)}
        >
          ↓
        </Button>
        <Button
          variant="ghost"
          size="sm"
          disabled={disabled}
          aria-label={`Remove ${frame.title}`}
          title={`Remove ${frame.title}`}
          onClick={remove}
        >
          ×
        </Button>
      </div>
    </li>
  );
}

export default function Home() {
  const [frames, setFrames] = useState<Draft[]>(() =>
    initialFrames('pay-after-swap'),
  );
  const [preset, setPreset] = useState<SequencePreset | undefined>(
    'pay-after-swap',
  );
  const [owner, setOwner] = useState<Address>();
  const [sender, setSender] = useState<Address>();
  const [amount, setAmount] = useState('1');
  const [slippage, setSlippage] = useState('1');
  const [recipient, setRecipient] = useState('');
  const [quote, setQuote] = useState<Quote>();
  const [initialized, setInitialized] = useState(false);
  const [busy, setBusy] = useState('');
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');
  const [balances, setBalances] = useState<Balances>();
  const [fees, setFees] = useState<Fees>();
  const [virtualFees, setVirtualFees] = useState<Fees>();
  const [gasPriceOverride, setGasPriceOverride] = useState<string>();
  const [priorityAllowance, setPriorityAllowance] = useState('0');
  const [fundEth, setFundEth] = useState('0.002');
  const [overhead, setOverhead] = useState(DEFAULT_OVERHEAD_GAS);
  const [results, setResults] = useState<readonly FrameResult[]>();
  const [receipt, setReceipt] = useState<Hex>();
  const [charged, setCharged] = useState<bigint>();
  const provider = useRef<Provider | undefined>(undefined);
  const revision = useRef(0);
  const current = useRef({ frames, busy, preset });
  useEffect(() => {
    current.current = { frames, busy, preset };
  }, [frames, busy, preset]);
  const sensors = useSensors(
    useSensor(PointerSensor, { activationConstraint: { distance: 8 } }),
    useSensor(KeyboardSensor, {
      coordinateGetter: sortableKeyboardCoordinates,
    }),
  );
  function invalidate() {
    revision.current++;
    setVirtualFees(undefined);
    setResults(undefined);
    setReceipt(undefined);
    setCharged(undefined);
    setError('');
    setNotice('');
  }
  function edit(next: Draft[]) {
    invalidate();
    // Once calls are customized, the editor must not replace their calldata when quoting.
    const previous = current.current.frames;
    const customized =
      next.length !== previous.length ||
      next.some((frame) => {
        const before = previous.find((candidate) => candidate.id === frame.id);
        return (
          !before ||
          ['mode', 'target', 'data', 'value'].some(
            (key) => frame[key as keyof Draft] !== before[key as keyof Draft],
          )
        );
      });
    if (customized) {
      setPreset(undefined);
      setQuote(undefined);
      setInitialized(true);
    }
    setFrames(next);
  }
  function reorder({ active, over }: DragEndEvent) {
    if (over && active.id !== over.id && !busy)
      edit(
        arrayMove(
          frames,
          frames.findIndex((f) => f.id === active.id),
          frames.findIndex((f) => f.id === over.id),
        ),
      );
  }
  function assertFresh(version: number) {
    if (version !== revision.current)
      throw new Error(
        'The wallet or frames changed. Prepare the operation again.',
      );
  }
  async function run(label: string, action: () => Promise<unknown>) {
    setBusy(label);
    setError('');
    setNotice('');
    try {
      await action();
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy('');
    }
  }
  useEffect(() => {
    const p = window.ethereum;
    provider.current = p;
    function changed() {
      invalidate();
      setOwner(undefined);
      setSender(undefined);
      setBalances(undefined);
      setQuote(undefined);
      setInitialized(false);
      const selected = current.current.preset ?? 'pay-after-swap';
      setFrames(initialFrames(selected));
      setPreset(selected);
      setNotice(
        'Wallet changed. Connect again to select the active Sepolia account.',
      );
    }
    p?.on?.('accountsChanged', changed);
    p?.on?.('chainChanged', changed);
    return () => {
      p?.removeListener?.('accountsChanged', changed);
      p?.removeListener?.('chainChanged', changed);
    };
  }, []);
  // Optional WebMCP: reads and reordering only. Signing and broadcasting stay in wallet controls.
  useEffect(() => {
    type Context = {
      registerTool: (
        tool: object,
        options: { signal: AbortSignal },
      ) => void | Promise<void>;
    };
    const context = (document as Document & { modelContext?: Context })
      .modelContext;
    if (!context?.registerTool) return;
    const lifecycle = new AbortController();
    const tools = [
      {
        name: 'read_frame_sequence',
        description:
          'Read the visible frame sequence. Does not contact a wallet.',
        inputSchema: {
          type: 'object',
          properties: {},
          additionalProperties: false,
        },
        annotations: { readOnlyHint: true },
        execute: () => ({ frames: current.current.frames }),
      },
      {
        name: 'reorder_frames',
        description:
          'Reorder all visible frames by ID and discard any prepared signature. Does not sign or submit a transaction.',
        inputSchema: {
          type: 'object',
          properties: { ids: { type: 'array', items: { type: 'string' } } },
          required: ['ids'],
          additionalProperties: false,
        },
        annotations: { readOnlyHint: false },
        execute: (input: unknown) => {
          if (current.current.busy)
            throw new Error('Wait for the current action to finish.');
          const ids = (input as { ids?: unknown })?.ids;
          const existing = current.current.frames;
          if (
            !Array.isArray(ids) ||
            ids.length !== existing.length ||
            new Set(ids).size !== ids.length ||
            ids.some(
              (id) =>
                typeof id !== 'string' || !existing.some((f) => f.id === id),
            )
          )
            throw new Error('Provide each current frame ID exactly once.');
          const next = ids.map((id) => existing.find((f) => f.id === id)!);
          flushSync(() => edit(next));
          return { ids: next.map((f) => f.id) };
        },
      },
    ];
    for (const tool of tools) {
      try {
        Promise.resolve(
          context.registerTool(tool, { signal: lifecycle.signal }),
        ).catch(() => {});
      } catch {}
    }
    return () => lifecycle.abort();
  }, []);
  async function activeWallet(expected = owner) {
    if (!provider.current || !expected)
      throw new Error('Connect a browser wallet first.');
    const wallet = createWalletClient({
      chain: sepolia,
      transport: custom(provider.current),
    });
    const [addresses, chain] = await Promise.all([
      wallet.getAddresses(),
      wallet.getChainId(),
    ]);
    if (
      chain !== sepolia.id ||
      addresses[0]?.toLowerCase() !== expected.toLowerCase()
    )
      throw new Error(
        'Select the connected account on Ethereum Sepolia in your wallet.',
      );
    return wallet;
  }
  async function refresh(account = sender, signer = owner) {
    if (!entryPoint || !account || !signer) return;
    const [eth, usdc, deposit, credit, code, fee] = await Promise.all([
      client.getBalance({ address: account }),
      client.readContract({
        address: USDC,
        abi: tokenAbi,
        functionName: 'balanceOf',
        args: [account],
      }),
      client.readContract({
        address: entryPoint,
        abi: vframeAbi,
        functionName: 'deposits',
        args: [account],
      }),
      client.readContract({
        address: entryPoint,
        abi: vframeAbi,
        functionName: 'deposits',
        args: [signer],
      }),
      client.getCode({ address: account }),
      client.estimateFeesPerGas(),
    ]);
    if (code && code !== '0x') {
      const actual = await client.readContract({
        address: account,
        abi: accountAbi,
        functionName: 'owner',
      });
      if (actual.toLowerCase() !== signer.toLowerCase())
        throw new Error(
          'This deterministic account has a different current owner.',
        );
    }
    const updated = {
      eth,
      usdc,
      deposit,
      credit,
      deployed: !!code && code !== '0x',
    };
    setBalances(updated);
    setFees(fee);
    return { balances: updated, fees: fee };
  }
  async function connect() {
    if (!window.ethereum)
      throw new Error(
        'Open this demo in a browser with an Ethereum wallet extension.',
      );
    provider.current = window.ethereum;
    const wallet = createWalletClient({
      chain: sepolia,
      transport: custom(window.ethereum),
    });
    await wallet.requestAddresses();
    if ((await wallet.getChainId()) !== sepolia.id)
      await wallet.switchChain({ id: sepolia.id });
    const [signer] = await wallet.getAddresses();
    if (!signer) throw new Error('No wallet account selected.');
    invalidate();
    const version = revision.current;
    setOwner(signer);
    setRecipient(signer);
    if (!entryPoint || !factory) {
      setNotice(
        'Wallet connected. Run the deployment command to configure the Sepolia contracts.',
      );
      return;
    }
    const [chain, epCode, factoryCode, linked] = await Promise.all([
      client.getChainId(),
      client.getCode({ address: entryPoint }),
      client.getCode({ address: factory }),
      client.readContract({
        address: factory,
        abi: factoryAbi,
        functionName: 'entryPoint',
      }),
    ]);
    if (
      chain !== sepolia.id ||
      !epCode ||
      epCode === '0x' ||
      !factoryCode ||
      factoryCode === '0x' ||
      linked.toLowerCase() !== entryPoint.toLowerCase()
    )
      throw new Error(
        'The configured contracts are not a matching Sepolia deployment. Run the deployment script and rebuild the demo.',
      );
    const predicted = await client.readContract({
      address: factory,
      abi: factoryAbi,
      functionName: 'getAddress',
      args: [signer, SALT],
    });
    assertFresh(version);
    setSender(predicted);
    await refresh(predicted, signer);
  }
  async function selectSequence(next: SequencePreset) {
    invalidate();
    setPreset(next);
    setFrames(initialFrames(next));
    setQuote(undefined);
    setInitialized(false);
    if (!owner || !sender || !factory) {
      setNotice(
        'Sequence loaded. Connect your wallet, then Sign, simulate & submit to prepare and send it.',
      );
      return;
    }
    await buildSwap(next);
  }
  async function buildSwap(
    selected: SequencePreset = preset ?? 'swap-spend',
    drafts?: Draft[],
    snapshot?: FundingSnapshot,
  ) {
    if (!owner || !sender || !factory)
      throw new Error('Connect a wallet after configuring the deployment.');
    if (selected === 'swap-spend' && !isAddress(recipient))
      throw new Error('Enter a valid ETH recipient.');
    invalidate();
    const version = revision.current;
    const fresh = snapshot ?? (await refresh());
    assertFresh(version);
    if (!fresh) throw new Error('Connect a wallet before quoting.');
    const slippageBps = Number(decimal(slippage, 2));
    const budgeted = accountDeploymentBudget(
      drafts ?? initialFrames(selected),
      fresh.balances.deployed,
    );
    const gasLimit = gasReservation(budgeted, overhead, 1n);
    if (gasLimit === undefined)
      throw new Error('Enter valid frame and overhead gas budgets.');
    const priceOverride =
      gasPriceOverride === undefined ? undefined : decimal(gasPriceOverride, 9);
    const plan =
      selected === 'pay-after-swap'
        ? await quoteAffordableGasSwap({
            networkFees: fresh.fees,
            gasLimit,
            ...fresh.balances,
            slippageBps,
            priceOverride,
            priorityAllowance: decimal(priorityAllowance, 9),
          })
        : {
            quote: await quoteSwap(decimal(amount, 6), slippageBps),
            fees: reimbursementFees(
              fresh.fees,
              gasLimit,
              fresh.balances.eth + fresh.balances.deposit,
              priceOverride,
              decimal(priorityAllowance, 9),
            ),
          };
    const next = plan.quote;
    assertFresh(version);
    setQuote(next);
    setVirtualFees(plan.fees);
    if (selected === 'pay-after-swap') setAmount(formatDecimal(next.amount, 6));
    const generated = makeSwapFrames({
      owner,
      sender,
      factory,
      recipient:
        selected === 'pay-after-swap' ? sender : (recipient as Address),
      amount: next.amount,
      minimum: next.minimum,
      fee: next.fee,
      preset: selected,
    });
    const nextFrames = refillSwapFrames(budgeted, generated);
    setFrames(nextFrames);
    setInitialized(true);
    setNotice(
      'Swap frames are ready. You can edit or reorder them before signing.',
    );
    return { frames: nextFrames, quote: next, fees: plan.fees };
  }
  async function fund(token: boolean) {
    if (!sender || !owner) throw new Error('Connect a wallet first.');
    const wallet = await activeWallet();
    const value = token
      ? preset === 'pay-after-swap' && quote && balances
        ? quote.amount > balances.usdc
          ? quote.amount - balances.usdc
          : 0n
        : decimal(amount, 6)
      : decimal(fundEth, 18);
    if (value <= 0n) throw new Error('Funding amount must be positive.');
    const hash = token
      ? await wallet.writeContract({
          account: owner,
          address: USDC,
          abi: tokenAbi,
          functionName: 'transfer',
          args: [sender, value],
        })
      : await wallet.sendTransaction({ account: owner, to: sender, value });
    const mined = await client.waitForTransactionReceipt({ hash });
    if (mined.status !== 'success')
      throw new Error('Funding transaction reverted.');
    await refresh();
    setNotice(`Funding confirmed: ${hash}`);
  }
  async function prepare() {
    if (!owner || !sender || !entryPoint)
      throw new Error('Connect your wallet first.');
    setResults(undefined);
    setReceipt(undefined);
    const startingVersion = revision.current;
    const wallet = await activeWallet();
    const [nonce, snapshot, block] = await Promise.all([
      client.readContract({
        address: entryPoint,
        abi: vframeAbi,
        functionName: 'nonces',
        args: [sender, 0n],
      }),
      refresh(),
      client.getBlock(),
    ]);
    assertFresh(startingVersion);
    if (!snapshot) throw new Error('Connect your wallet first.');
    const fee = snapshot.fees;
    let drafts = frames;
    let reimbursement: Fees;
    if (!initialized || preset === 'pay-after-swap') {
      if (!preset) throw new Error('Select a sequence or add frames first.');
      const built = await buildSwap(preset, drafts, snapshot);
      drafts = built.frames;
      reimbursement = built.fees;
      if (
        preset === 'pay-after-swap' &&
        built.quote.amount > snapshot.balances.usdc
      ) {
        const missing = built.quote.amount - snapshot.balances.usdc;
        throw new Error(
          `The swap needs ${formatDecimal(built.quote.amount, 6)} USDC, including the 25% gas margin. Add ${formatDecimal(missing, 6)} USDC to the account or fund it with ETH, then try again.`,
        );
      }
    } else {
      const gasLimit = gasReservation(drafts, overhead, 1n);
      if (gasLimit === undefined) throw new Error('Enter valid gas budgets.');
      reimbursement = reimbursementFees(
        fee,
        gasLimit,
        snapshot.balances.eth + snapshot.balances.deposit,
        gasPriceOverride === undefined
          ? undefined
          : decimal(gasPriceOverride, 9),
        decimal(priorityAllowance, 9),
      );
      setVirtualFees(reimbursement);
    }
    const version = revision.current;
    if (!/^\d+$/.test(overhead) || BigInt(overhead) < 40000n)
      throw new Error('Overhead must be an integer of at least 40,000 gas.');
    const transaction: Transaction = {
      sender,
      nonceKeys: [0n],
      nonce,
      validUntil: Number(block.timestamp) + 600,
      overheadGasLimit: BigInt(overhead),
      ...reimbursement,
      frames: encodeFrames(drafts),
      signatures: [
        { scheme: 1, signer: owner, message: zeroHash, signature: '0x' },
      ],
    };
    const gas = outerGas(transaction);
    const deploymentError =
      'The deployed vFrame uses the older fee model. Deploy the updated vFrame and factory, then rebuild this demo to use the affordable price range.';
    try {
      const quoteCall = {
        abi: vframeAbi,
        functionName: 'getGasQuote',
        args: [transaction],
      } as const;
      // Supply network fees so RPC eth_call preserves the block's base fee.
      const { data } = await client
        .call({
          account: owner,
          to: entryPoint,
          data: encodeFunctionData(quoteCall),
          blockNumber: block.number,
          gas,
          ...fee,
        })
        .catch((error) => {
          throw getContractError(error, { ...quoteCall, address: entryPoint });
        });
      const onchainQuote = decodeFunctionResult({
        ...quoteCall,
        data: data ?? '0x',
      });
      if (
        onchainQuote.maxCost !==
          gasReservation(
            drafts,
            overhead,
            reimbursementCeiling(reimbursement),
          ) ||
        onchainQuote.gasPrice !==
          reimbursementPrice(block.baseFeePerGas ?? 0n, reimbursement)
      )
        throw new Error(deploymentError);
    } catch (error) {
      const cause =
        error instanceof BaseError
          ? error.walk((item) => item instanceof ContractFunctionRevertedError)
          : undefined;
      if (
        cause instanceof ContractFunctionRevertedError &&
        cause.data?.errorName === 'InvalidGasParameters'
      )
        throw new Error(deploymentError);
      throw error;
    }
    const onchain = await client.readContract({
      address: entryPoint,
      abi: vframeAbi,
      functionName: 'getTransactionHash',
      args: [transaction],
    });
    if (transactionHash(entryPoint, transaction) !== onchain)
      throw new Error(
        'The local and deployed signing hashes do not match. Sync the ABI and deployment.',
      );
    // Payment may follow execution. Simulate the complete sequence to check funding at
    // the payment frame, rather than requiring ETH before swap proceeds arrive.
    assertFresh(version);
    const signature = await wallet.signTypedData({
      account: owner,
      ...typedData(entryPoint, transaction),
    });
    assertFresh(version);
    await activeWallet();
    transaction.signatures[0].signature = frameSignature(signature);
    const { result } = await client.simulateContract({
      account: owner,
      address: entryPoint,
      abi: vframeAbi,
      functionName: 'handle',
      args: [transaction],
      gas,
      ...fee,
    });
    assertFresh(version);
    setResults(result);
    setFees(fee);
    if (result.some((frame) => frame.status !== 1 || frame.rolledBack)) {
      throw new Error(
        'Simulation found a failed or rolled-back frame. Fix the sequence before submitting.',
      );
    }
    return { transaction, revision: version };
  }
  async function submit(prepared: Prepared) {
    if (!owner || !entryPoint) throw new Error('Connect your wallet first.');
    const { transaction, revision: version } = prepared;
    assertFresh(version);
    const wallet = await activeWallet();
    const networkFees = await client.estimateFeesPerGas();
    setFees(networkFees);
    // Re-simulate immediately before requesting broadcast; state and quotes can change.
    const { result } = await client.simulateContract({
      account: owner,
      address: entryPoint,
      abi: vframeAbi,
      functionName: 'handle',
      args: [transaction],
      gas: outerGas(transaction),
      ...networkFees,
    });
    setResults(result);
    if (result.some((frame) => frame.status !== 1 || frame.rolledBack)) {
      throw new Error(
        'The latest simulation contains a failed or rolled-back frame. Nothing was submitted.',
      );
    }
    assertFresh(version);
    await activeWallet();
    const hash = await wallet.writeContract({
      account: owner,
      address: entryPoint,
      abi: vframeAbi,
      functionName: 'handle',
      args: [transaction],
      gas: outerGas(transaction),
      ...networkFees,
    });
    setReceipt(hash);
    setNotice('Submitted. Waiting for the Sepolia receipt…');
    const mined = await client.waitForTransactionReceipt({ hash });
    if (mined.status !== 'success') {
      setResults(undefined);
      throw new Error(
        'The outer transaction reverted. The wallet paid network gas.',
      );
    }
    const logs = mined.logs.filter(
      (log) => log.address.toLowerCase() === entryPoint!.toLowerCase(),
    );
    const events = parseEventLogs({
      abi: vframeAbi,
      logs,
      eventName: 'FrameResult',
    });
    setResults(
      events.map((e) => ({
        status: e.args.status,
        rolledBack: e.args.rolledBack,
        returnData: e.args.returnData,
      })),
    );
    const handled = parseEventLogs({
      abi: vframeAbi,
      logs,
      eventName: 'TransactionHandled',
    })[0];
    setCharged(handled?.args.chargedFee);
    setNotice(
      'Mined on Sepolia. The results below come from the contract’s frame events.',
    );
    await refresh();
  }
  async function withdrawCredit() {
    if (!owner || !entryPoint || !balances?.credit) return;
    const wallet = await activeWallet();
    const hash = await wallet.writeContract({
      account: owner,
      address: entryPoint,
      abi: vframeAbi,
      functionName: 'withdrawTo',
      args: [owner, balances.credit],
    });
    const result = await client.waitForTransactionReceipt({ hash });
    if (result.status !== 'success') throw new Error('Withdrawal reverted.');
    await refresh();
    setNotice('Relayer credit withdrawn to your wallet.');
  }
  const maximum = gasReservation(
    frames,
    overhead,
    virtualFees ? reimbursementCeiling(virtualFees) : undefined,
  );
  const subsidized =
    fees &&
    virtualFees &&
    reimbursementCeiling(virtualFees) < fees.maxFeePerGas;
  const gasTarget =
    maximum === undefined ? undefined : bufferedGasCost(maximum);
  const gasCovered =
    quote &&
    gasTarget !== undefined &&
    quote.minimum + (balances?.eth ?? 0n) + (balances?.deposit ?? 0n) >=
      gasTarget;
  const usdcShortfall =
    quote && balances
      ? quote.amount > balances.usdc
        ? quote.amount - balances.usdc
        : 0n
      : undefined;
  const failed = results?.some((r) => r.status !== 1 || r.rolledBack);
  return (
    <div className="shell">
      <header>
        <Link className="brand" href="/">
          vFrame <span className="muted">/ playground</span>
        </Link>
        <div className="header-right">
          <span className="network">Ethereum Sepolia</span>
          <Button
            variant="secondary"
            size="sm"
            disabled={!!busy}
            onClick={() => run('Connecting wallet…', connect)}
          >
            {owner ? short(owner) : 'Connect wallet'}
          </Button>
        </div>
      </header>
      <main>
        {!configReady && (
          <div className="notice">
            <strong>Sepolia deployment is not configured yet.</strong> Deploy
            with the command in <code>web/README.md</code>; it configures the
            addresses automatically. Rebuild the demo afterward. The editor
            works before deployment.
          </div>
        )}
        <div className="workspace">
          <section>
            <div className="section-head">
              <h1>
                Frames <span className="muted">/ {frames.length}</span>
              </h1>
              <Button
                variant="secondary"
                size="sm"
                disabled={!!busy}
                onClick={() => {
                  edit([customFrame(1)]);
                  setInitialized(true);
                  setQuote(undefined);
                  setPreset(undefined);
                }}
              >
                New sequence
              </Button>
            </div>
            <DndContext
              sensors={sensors}
              collisionDetection={closestCenter}
              onDragEnd={reorder}
            >
              <SortableContext
                items={frames}
                strategy={verticalListSortingStrategy}
              >
                <ol className="frame-list">
                  {frames.map((frame, index) => (
                    <FrameRow
                      key={frame.id}
                      frame={frame}
                      index={index}
                      count={frames.length}
                      disabled={!!busy}
                      update={(patch) =>
                        edit(
                          frames.map((f) =>
                            f.id === frame.id ? { ...f, ...patch } : f,
                          ),
                        )
                      }
                      remove={() =>
                        edit(frames.filter((f) => f.id !== frame.id))
                      }
                      move={(direction) =>
                        edit(arrayMove(frames, index, index + direction))
                      }
                    />
                  ))}
                </ol>
              </SortableContext>
            </DndContext>
            {!frames.length && (
              <p className="notice">
                Add a VERIFY frame to approve execution and payment, then add
                your calls.
              </p>
            )}
            <div
              className="actions frame-palette"
              aria-label="Add frame blocks"
            >
              {names.map((name, mode) => (
                <Button
                  key={name}
                  variant="secondary"
                  size="sm"
                  className="frame-add"
                  data-mode={mode}
                  disabled={!!busy || frames.length >= 64}
                  onClick={() => {
                    edit([...frames, customFrame(mode)]);
                    setInitialized(true);
                  }}
                >
                  + {name}
                </Button>
              ))}
            </div>
            <details className="advanced">
              <summary>Transaction settings & help</summary>
              <div className="fields">
                <p className="help">
                  Drag to reorder, or use ↑ / ↓. Keyboard: Space to pick up a
                  handle, arrows to move, Space to drop. Reordering clears the
                  prepared signature.
                </p>
                <Input
                  label="EntryPoint overhead gas"
                  value={overhead}
                  inputMode="numeric"
                  disabled={!!busy}
                  onChange={(e) => {
                    invalidate();
                    setOverhead(e.target.value);
                  }}
                />
                <p className="help">
                  Nonce key 0 · ten-minute signature expiry. The wallet pays
                  network gas. vFrame reimbursement uses its separate signed
                  price range.
                </p>
              </div>
            </details>
            {subsidized && (
              <output className="notice block" aria-live="polite">
                <strong>Your EOA may pay more than it receives.</strong> The
                account reimburses at{' '}
                {formatDecimal(virtualFees.maxFeePerGas, 9)}–
                {formatDecimal(reimbursementCeiling(virtualFees), 9)} gwei/gas.
                The current network fee cap is{' '}
                {formatDecimal(fees.maxFeePerGas, 9)} gwei/gas. Your wallet
                covers the difference; the account funds its own gas deposit.
              </output>
            )}
            <div className="actions submit-actions">
              <Button
                variant="primary"
                disabled={!!busy || !sender || !frames.length}
                onClick={() =>
                  run('Signing & simulating…', async () => {
                    const prepared = await prepare();
                    setBusy('Confirm the transaction in your wallet…');
                    await submit(prepared);
                  })
                }
              >
                Sign, simulate & submit
              </Button>
            </div>
            <output aria-live="polite">
              {busy && <span className="notice block">{busy}</span>}
              {notice && <span className="notice block">{notice}</span>}
            </output>
            {error && (
              <div role="alert" className="notice error">
                <strong>Could not complete the action</strong>
                <details open>
                  <summary>Details</summary>
                  <p className="code">{error}</p>
                </details>
              </div>
            )}
            {results && (
              <section className="results">
                <div className="section-head">
                  <h2>{receipt ? 'On-chain results' : 'Simulation results'}</h2>
                  <span className={failed ? 'text-failure' : 'text-success'}>
                    {failed
                      ? 'Some frames failed or rolled back'
                      : 'All frames succeeded'}
                  </span>
                </div>
                {receipt && (
                  <a
                    href={`https://sepolia.etherscan.io/tx/${receipt}`}
                    target="_blank"
                    rel="noreferrer"
                  >
                    View transaction ↗
                  </a>
                )}
                {charged !== undefined && (
                  <p className="help">
                    Relayer reimbursement: {formatEther(charged)} ETH
                  </p>
                )}
                {results.map((result, i) => (
                  <div className="result" key={i}>
                    <div className="stat">
                      <strong>
                        {String(i).padStart(2, '0')} · {frames[i]?.title}
                      </strong>
                      <span>{statusText(result)}</span>
                    </div>
                    {result.returnData !== '0x' && (
                      <details>
                        <summary>Return data</summary>
                        <pre className="code">{result.returnData}</pre>
                      </details>
                    )}
                  </div>
                ))}
              </section>
            )}
          </section>
          <aside className="aside">
            <section>
              <h2>Sequences</h2>
              <div className="presets">
                <Button
                  variant="secondary"
                  size="sm"
                  aria-pressed={preset === 'pay-after-swap'}
                  disabled={!!busy}
                  onClick={() =>
                    run('Loading swap → gas payment…', () =>
                      selectSequence('pay-after-swap'),
                    )
                  }
                >
                  Test pay for tx after swap
                </Button>
                <Button
                  variant="secondary"
                  size="sm"
                  aria-pressed={preset === 'swap-spend'}
                  disabled={!!busy}
                  onClick={() =>
                    run('Loading swap → spend…', () =>
                      selectSequence('swap-spend'),
                    )
                  }
                >
                  Swap & spend ETH
                </Button>
              </div>
              <div className="fields">
                <Input
                  label="vFrame minimum gas price (gwei)"
                  value={
                    gasPriceOverride ??
                    (virtualFees
                      ? formatDecimal(virtualFees.maxFeePerGas, 9)
                      : '')
                  }
                  placeholder="Auto · fits account funds"
                  inputMode="decimal"
                  disabled={!!busy}
                  onChange={(event) => {
                    invalidate();
                    setGasPriceOverride(event.target.value || undefined);
                    setQuote(undefined);
                    if (preset) setInitialized(false);
                  }}
                />
                <div className="actions">
                  <Button
                    size="sm"
                    variant={
                      gasPriceOverride === undefined ? 'primary' : 'secondary'
                    }
                    aria-pressed={gasPriceOverride === undefined}
                    disabled={!!busy}
                    onClick={() => {
                      invalidate();
                      setGasPriceOverride(undefined);
                      setPriorityAllowance('0');
                      setQuote(undefined);
                      if (preset) setInitialized(false);
                    }}
                  >
                    Auto
                  </Button>
                  <span className="muted">
                    {gasPriceOverride === undefined
                      ? 'Account-funded · 25% margin'
                      : 'Custom price range'}
                  </span>
                </div>
              </div>
              <details className="sequence-settings">
                <summary>
                  Swap settings ·{' '}
                  {preset === 'pay-after-swap'
                    ? quote
                      ? `${formatDecimal(quote.amount, 6)} USDC · auto`
                      : 'automatic amount'
                    : `${amount || '0'} USDC`}
                </summary>
                <fieldset disabled={!!busy} className="fields">
                  <Input
                    label="Priority allowance above minimum (gwei)"
                    inputMode="decimal"
                    value={priorityAllowance}
                    onChange={(event) => {
                      invalidate();
                      setPriorityAllowance(event.target.value);
                      setQuote(undefined);
                      if (preset) setInitialized(false);
                    }}
                  />
                  <p className="help">
                    Minimum = maxFeePerGas. Maximum = minimum +
                    maxPriorityFeePerGas. vFrame clamps the network base fee to
                    this range. Zero allowance fixes the price.
                  </p>
                  {preset === 'pay-after-swap' ? (
                    <p className="help">
                      The swap stays within the account’s USDC balance. Auto
                      lowers the vFrame price range to fit its minimum ETH
                      output with a 25% margin. Existing ETH and deposits count
                      too. Recalculated before signing.
                    </p>
                  ) : (
                    <Input
                      label="Circle USDC to swap"
                      value={amount}
                      inputMode="decimal"
                      onChange={(e) => {
                        invalidate();
                        setAmount(e.target.value);
                        setQuote(undefined);
                        setInitialized(false);
                      }}
                    />
                  )}
                  {preset !== 'pay-after-swap' && (
                    <Input
                      label="ETH recipient"
                      value={recipient}
                      placeholder="0x…"
                      onChange={(e) => {
                        invalidate();
                        setRecipient(e.target.value);
                        setQuote(undefined);
                        setInitialized(false);
                      }}
                    />
                  )}
                  <Input
                    label="Slippage tolerance (%)"
                    value={slippage}
                    inputMode="decimal"
                    onChange={(e) => {
                      invalidate();
                      setSlippage(e.target.value);
                      setQuote(undefined);
                      setInitialized(false);
                    }}
                  />
                  <Button
                    variant="secondary"
                    disabled={!sender || !preset}
                    onClick={() =>
                      run('Quoting USDC → ETH…', async () => {
                        await buildSwap();
                      })
                    }
                  >
                    Update sequence
                  </Button>
                </fieldset>
              </details>
              {quote && (
                <div className="quote">
                  {preset === 'pay-after-swap' && (
                    <div className="stat">
                      <span>USDC to swap · auto</span>
                      <strong>{formatDecimal(quote.amount, 6)}</strong>
                    </div>
                  )}
                  <div className="stat">
                    <span>Quoted ETH</span>
                    <strong>{formatEther(quote.output)}</strong>
                  </div>
                  <div className="stat">
                    <span>
                      {preset === 'pay-after-swap'
                        ? 'Minimum ETH for gas'
                        : 'ETH to spend'}
                    </span>
                    <strong>{formatEther(quote.minimum)}</strong>
                  </div>
                  <p className="help">
                    Uniswap v3 · {quote.fee / 10000}% pool · block{' '}
                    {quote.block.toString()}.{' '}
                    {preset === 'pay-after-swap'
                      ? 'The first VERIFY authorizes execution. Approve, swap and unwrap run atomically. The final VERIFY pays gas from the output.'
                      : 'Approve, swap, unwrap and spend run atomically. Extra ETH stays in the account.'}
                  </p>
                  {preset === 'pay-after-swap' && (
                    <>
                      <p className={`help ${gasCovered ? 'text-success' : ''}`}>
                        {gasCovered
                          ? 'Gas reservation covered, plus 25% margin after slippage.'
                          : 'Gas requirements changed. The amount will be recalculated before signing.'}
                      </p>
                      {usdcShortfall !== undefined && usdcShortfall > 0n && (
                        <p className="help text-failure">
                          Add {formatDecimal(usdcShortfall, 6)} USDC to the
                          account, or fund it with ETH to reduce the swap
                          amount.
                        </p>
                      )}
                    </>
                  )}
                </div>
              )}
              <p className="help">
                USDC from{' '}
                <a
                  href="https://faucet.circle.com/"
                  target="_blank"
                  rel="noreferrer"
                >
                  Circle’s faucet ↗
                </a>{' '}
                · Ethereum Sepolia.
              </p>
            </section>
            <section>
              <h2>Your account</h2>
              {sender ? (
                <>
                  <a
                    className="address"
                    href={explorer(sender)}
                    target="_blank"
                    rel="noreferrer"
                    title={sender}
                  >
                    {short(sender)} ↗
                  </a>
                  <p className="help">
                    {balances?.deployed
                      ? 'Account deployed.'
                      : 'Deploys with the first DEFAULT frame.'}
                  </p>
                  {balances && (
                    <>
                      <div className="stat">
                        <span>Available ETH</span>
                        <strong>{formatEther(balances.eth)}</strong>
                      </div>
                      <div className="stat">
                        <span>USDC</span>
                        <strong>{formatDecimal(balances.usdc, 6)}</strong>
                      </div>
                      <div className="stat">
                        <span>Gas deposit</span>
                        <strong>{formatEther(balances.deposit)} ETH</strong>
                      </div>
                    </>
                  )}
                  {maximum !== undefined && (
                    <div className="stat">
                      <span>Max gas reservation</span>
                      <strong>{formatEther(maximum)} ETH</strong>
                    </div>
                  )}
                  <details className="account-funding">
                    <summary>Fund account</summary>
                    <div className="fields">
                      <Input
                        label="Sepolia ETH to fund"
                        value={fundEth}
                        inputMode="decimal"
                        disabled={!!busy}
                        onChange={(e) => setFundEth(e.target.value)}
                      />
                      <Button
                        variant="secondary"
                        disabled={!!busy}
                        onClick={() =>
                          run('Funding account with ETH…', () => fund(false))
                        }
                      >
                        Send ETH to account
                      </Button>
                      <Button
                        variant="secondary"
                        disabled={
                          !!busy ||
                          (preset === 'pay-after-swap' &&
                            (!quote || usdcShortfall === 0n))
                        }
                        onClick={() =>
                          run('Funding account with USDC…', () => fund(true))
                        }
                      >
                        {preset === 'pay-after-swap'
                          ? !quote
                            ? 'Calculate USDC first'
                            : usdcShortfall === 0n
                              ? 'USDC funded'
                              : `Send ${formatDecimal(usdcShortfall ?? quote.amount, 6)} USDC to account`
                          : `Send ${amount || '0'} USDC to account`}
                      </Button>
                      <Button
                        variant="ghost"
                        disabled={!!busy}
                        onClick={() =>
                          run('Refreshing balances…', () => refresh())
                        }
                      >
                        Refresh balances
                      </Button>
                    </div>
                    <p className="help">
                      {preset === 'pay-after-swap'
                        ? 'Fund the account with USDC. Swap proceeds can cover its gas reservation; no starting account ETH is needed when the output is sufficient.'
                        : 'Fund the account with USDC and ETH for the gas reservation before the swap.'}{' '}
                      Your wallet needs Sepolia ETH to submit the outer
                      transaction.
                    </p>
                  </details>
                  {!!balances?.credit && (
                    <>
                      <p className="help">
                        Your wallet has {formatEther(balances.credit)} ETH of
                        relayer credit.
                      </p>
                      <Button
                        variant="ghost"
                        disabled={!!busy}
                        onClick={() =>
                          run('Withdrawing relayer credit…', withdrawCredit)
                        }
                      >
                        Withdraw relayer credit
                      </Button>
                    </>
                  )}
                </>
              ) : (
                <p className="help">
                  Connect your wallet to get a deterministic account address.
                  Accounts can receive ETH and USDC before deployment.
                </p>
              )}
            </section>
            <details>
              <summary>Contracts & calldata</summary>
              <div className="fields">
                {[
                  ['vFrame', entryPoint],
                  ['Account factory', factory],
                  ['Circle USDC', USDC],
                  ['WETH', WETH],
                  ['Uniswap router', ROUTER],
                ].map(([label, address]) => (
                  <div key={label}>
                    <strong>{label}</strong>
                    <p className="address">
                      {address ? (
                        <a
                          href={explorer(address)}
                          target="_blank"
                          rel="noreferrer"
                        >
                          {address} ↗
                        </a>
                      ) : (
                        'Awaiting deployment'
                      )}
                    </p>
                  </div>
                ))}
                <p className="help">
                  Zero target means the sender account. VERIFY is a mutable CALL
                  in this harness. Atomic flags join a frame with the next one.
                </p>
                <details>
                  <summary>Frame JSON</summary>
                  <pre className="code">{JSON.stringify(frames, null, 2)}</pre>
                </details>
              </div>
            </details>
          </aside>
        </div>
      </main>
      <footer>
        <span>vFrame · contract-based frame testing</span>
        <div className="inline">
          <a href="https://github.com/leekt/FrameTx-toolkit/tree/main/vframe">
            Source ↗
          </a>
          <a href="https://eips.ethereum.org/EIPS/eip-8141">
            Frame transaction spec ↗
          </a>
        </div>
      </footer>
    </div>
  );
}
