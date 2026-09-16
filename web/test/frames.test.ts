import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawn } from 'node:child_process';
import { createServer } from 'node:net';
import {
  createPublicClient,
  createWalletClient,
  http,
  encodeFunctionData,
  parseEther,
  zeroHash,
  zeroAddress,
  decodeFunctionData,
  parseEventLogs,
  type Hex,
  type Address,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { sepolia } from 'viem/chains';
import { vframeAbi } from '../lib/vframeAbi';
import { factoryAbi } from '../lib/factoryAbi';
import { accountAbi } from '../lib/accountAbi';
import {
  makeSwapFrames,
  encodeFrames,
  frameSignature,
  transactionHash,
  typedData,
  outerGas,
  decimal,
  statusText,
  bufferedGasCost,
  gasSwapMinimum,
  outputBeforeSlippage,
  refillSwapFrames,
  initialFrames,
  DEFAULT_OVERHEAD_GAS,
  accountDeploymentBudget,
  affordableGasPrice,
  reimbursementFees,
  reimbursementCeiling,
  reimbursementPrice,
  gasReservation,
  routerAbi,
  tokenAbi,
  ROUTER,
  USDC,
  SALT,
  type Transaction,
} from '../lib/frames';

const owner = privateKeyToAccount(`0x${'1'.padStart(64, '0')}`);
const target = '0x000000000000000000000000000000000000bEEF' as Address;
const sender = '0x0000000000000000000000000000000000000001' as Address;
const factory = '0x0000000000000000000000000000000000000002' as Address;
const example = (preset: 'swap-spend' | 'pay-after-swap' = 'swap-spend') =>
  makeSwapFrames({
    owner: owner.address,
    sender,
    factory,
    recipient: target,
    amount: 1000000n,
    minimum: 100n,
    fee: 3000,
    preset,
  });

void test('swap preset encodes exact approval, bounded output, unwrap and ETH spend', () => {
  const frames = encodeFrames(example());
  assert.deepEqual(
    frames.map((f) => f.flags),
    [0, 3, 4, 4, 4, 0],
  );
  assert.deepEqual(
    frames.map((f) => f.mode),
    [0, 1, 2, 2, 2, 2],
  );
  assert.equal(frames[2].target, USDC);
  assert.deepEqual(
    decodeFunctionData({ abi: tokenAbi, data: frames[2].data }).args,
    [ROUTER, 1000000n],
  );
  const swap = decodeFunctionData({ abi: routerAbi, data: frames[3].data });
  assert.equal(swap.functionName, 'exactInputSingle');
  if (swap.functionName === 'exactInputSingle') {
    assert.equal(swap.args[0].amountOutMinimum, 100n);
    assert.equal(swap.args[0].recipient, ROUTER);
  }
  assert.deepEqual(
    decodeFunctionData({ abi: routerAbi, data: frames[4].data }).args,
    [100n, sender],
  );
  assert.equal(frames[5].value, 100n);
});

void test('pay-after-swap preset uses separate execution and payment VERIFY frames and retains swap ETH', () => {
  const frames = encodeFrames(example('pay-after-swap'));
  assert.deepEqual(
    frames.map((f) => f.flags),
    [0, 2, 4, 4, 0, 1],
  );
  assert.deepEqual(
    frames.map((f) => f.mode),
    [0, 1, 2, 2, 2, 1],
  );
  assert.equal(frames.filter((f) => f.mode === 1).length, 2);
  assert.equal(
    decodeFunctionData({ abi: accountAbi, data: frames[1].data }).functionName,
    'validateFrame',
  );
  assert.deepEqual(
    decodeFunctionData({ abi: accountAbi, data: frames[1].data }).args,
    [`0x${'00'.repeat(32)}`],
  );
  assert.deepEqual(
    decodeFunctionData({ abi: routerAbi, data: frames[4].data }).args,
    [100n, sender],
  );
  assert.equal(
    decodeFunctionData({ abi: accountAbi, data: frames[5].data }).functionName,
    'validateFrame',
  );
  assert.equal(frames[5].target, zeroAddress);
  assert.deepEqual(
    decodeFunctionData({ abi: accountAbi, data: frames[5].data }).args,
    [`0x${'00'.repeat(32)}`],
  );
  assert.ok(frames.every((f) => f.value === 0n));
});

void test('invalid decimals, modes, calldata and call budgets fail before signing', () => {
  assert.throws(() => decimal('0.0000001', 6));
  assert.throws(() => decimal('-1', 18));
  assert.throws(() => decimal('1e18', 18));
  for (const patch of [
    { data: '0x0' },
    { gasLimit: '0' },
    { target: '0x123' },
    { value: '-1' },
    { mode: 4 },
  ]) {
    const frames = example();
    frames[2] = { ...frames[2], ...patch };
    assert.throws(() => encodeFrames(frames));
  }
  const frames = example();
  frames[0].value = '1';
  assert.throws(() => encodeFrames(frames));
});

void test('gas swap sizing covers the full reservation plus margin after slippage and existing funds', () => {
  assert.equal(bufferedGasCost(100n), 125n);
  assert.equal(bufferedGasCost(1n), 2n);
  assert.equal(gasSwapMinimum(100n, 20n, 30n), 75n);
  assert.equal(gasSwapMinimum(100n, 125n, 0n), 0n);
  assert.equal(gasSwapMinimum(100n, 0n, 200n), 0n);
  for (const cost of [1n, 100n, 1234567890123456n]) {
    for (const slippage of [1, 100, 500]) {
      const minimum = gasSwapMinimum(cost, 0n, 0n);
      const output = outputBeforeSlippage(minimum, slippage);
      const afterSlippage = (output * BigInt(10000 - slippage)) / 10000n;
      assert.ok(afterSlippage >= minimum);
      assert.ok(((output - 1n) * BigInt(10000 - slippage)) / 10000n < minimum);
    }
  }
  for (const invalid of [0, -1, 501, 1.5]) {
    assert.throws(() => outputBeforeSlippage(100n, invalid));
  }
});

void test('automatic quote refresh retains user flags, gas budgets and ordering in the signed frames', () => {
  const drafts = initialFrames('pay-after-swap');
  drafts[1].flags = 3;
  drafts[3].gasLimit = '500000';
  [drafts[2], drafts[3]] = [drafts[3], drafts[2]];
  const generated = example('pay-after-swap');
  const refreshed = refillSwapFrames(drafts, generated);
  assert.deepEqual(
    refreshed.map((f) => f.id),
    drafts.map((f) => f.id),
  );
  const encoded = encodeFrames(refreshed);
  assert.equal(encoded[1].flags, 3);
  assert.equal(encoded[2].gasLimit, 500000n);
  assert.equal(encoded[2].data, generated[3].data);
  assert.equal(encoded[3].data, generated[2].data);
  assert.equal(drafts[2].data, '0x');
});

void test('gas budgets use the cheap idempotent factory path for deployed accounts and preserve overrides', () => {
  const fresh = initialFrames('pay-after-swap');
  assert.equal(gasReservation(fresh, DEFAULT_OVERHEAD_GAS, 1n), 1650000n);
  const deployed = accountDeploymentBudget(fresh, true);
  assert.equal(gasReservation(deployed, DEFAULT_OVERHEAD_GAS, 1n), 675000n);
  assert.equal(accountDeploymentBudget(deployed, false)[0].gasLimit, '1000000');
  deployed[0].gasLimit = '50000';
  assert.equal(accountDeploymentBudget(deployed, false)[0].gasLimit, '50000');
});

void test('automatic reimbursement range fits available funds including the whole priority allowance and margin', () => {
  const gas = 1650000n;
  const available = 633000000000000n;
  const network = { maxFeePerGas: 1250000000n, maxPriorityFeePerGas: 1000000n };
  const automatic = reimbursementFees(network, gas, available);
  assert.ok(automatic.maxFeePerGas < network.maxFeePerGas);
  assert.equal(automatic.maxPriorityFeePerGas, 0n);
  assert.equal(automatic.maxFeePerGas, affordableGasPrice(gas, available));
  assert.ok(
    bufferedGasCost(gas * reimbursementCeiling(automatic)) <= available,
  );
  assert.ok(
    bufferedGasCost(gas * (reimbursementCeiling(automatic) + 1n)) > available,
  );
  const range = reimbursementFees(
    network,
    gas,
    available,
    undefined,
    10000000n,
  );
  assert.equal(reimbursementCeiling(range), automatic.maxFeePerGas);
  assert.throws(() =>
    reimbursementFees(network, gas, available, automatic.maxFeePerGas, 1n),
  );
  assert.deepEqual(reimbursementFees(network, gas, 0n), {
    maxFeePerGas: 0n,
    maxPriorityFeePerGas: 0n,
  });
  assert.equal(reimbursementFees(network, gas, available, 0n).maxFeePerGas, 0n);
});

void test('base fee clamps between maxFeePerGas and maxFeePerGas plus maxPriorityFeePerGas', () => {
  const range = { maxFeePerGas: 3n, maxPriorityFeePerGas: 2n };
  assert.equal(reimbursementPrice(0n, range), 3n);
  assert.equal(reimbursementPrice(3n, range), 3n);
  assert.equal(reimbursementPrice(4n, range), 4n);
  assert.equal(reimbursementPrice(5n, range), 5n);
  assert.equal(reimbursementPrice(100n, range), 5n);
});

void test('signature format moves v from the end and normalizes 27/28', () => {
  const rs = '11'.repeat(64);
  assert.equal(frameSignature(`0x${rs}1c`), `0x01${rs}`);
  assert.equal(frameSignature(`0x${rs}00`), `0x00${rs}`);
  assert.throws(() => frameSignature(`0x${rs}02`));
});

void test('rolled-back successful calls are never presented as committed success', () => {
  assert.equal(
    statusText({ status: 1, rolledBack: true, returnData: '0x' }),
    'Returned · rolled back',
  );
  assert.equal(
    statusText({ status: 2, rolledBack: false, returnData: '0x' }),
    'Skipped',
  );
});

void test(
  'browser encoding matches vFrame and executes a counterfactual account on stock Osaka',
  { timeout: 60000 },
  async () => {
    const reservation = createServer();
    await new Promise<void>((r) => reservation.listen(0, '127.0.0.1', r));
    const port = (reservation.address() as { port: number }).port;
    await new Promise<void>((r) => reservation.close(() => r()));
    const node = spawn(
      'anvil',
      [
        '--host',
        '127.0.0.1',
        '--port',
        String(port),
        '--hardfork',
        'osaka',
        '--chain-id',
        '11155111',
        '--silent',
      ],
      { stdio: 'ignore' },
    );
    const rpc = `http://127.0.0.1:${port}`;
    const client = createPublicClient({
      chain: sepolia,
      transport: http(rpc, { retryCount: 0 }),
    });
    const wallet = createWalletClient({
      account: owner,
      chain: sepolia,
      transport: http(rpc),
    });
    try {
      let ready = false;
      for (let i = 0; i < 100; i++) {
        try {
          await client.getChainId();
          ready = true;
          break;
        } catch {
          await new Promise((r) => setTimeout(r, 30));
        }
      }
      assert.ok(ready, 'Anvil did not start');
      await client.request({
        method: 'anvil_setBalance' as never,
        params: [owner.address, '0x56bc75e2d63100000'] as never,
      });
      const artifact = (name: string) =>
        JSON.parse(
          readFileSync(
            new URL(
              `../../vframe/out/${name}.sol/${name}.json`,
              import.meta.url,
            ),
            'utf8',
          ),
        );
      const deployed = await client.waitForTransactionReceipt({
        hash: await wallet.deployContract({
          abi: vframeAbi,
          bytecode: artifact('vFrame').bytecode.object as Hex,
        }),
      });
      const ep = deployed.contractAddress!;
      const deployedFactory = await client.waitForTransactionReceipt({
        hash: await wallet.deployContract({
          abi: factoryAbi,
          bytecode: artifact('VFrameAccountFactory').bytecode.object as Hex,
          args: [ep],
        }),
      });
      const f = deployedFactory.contractAddress!;
      const account = await client.readContract({
        address: f,
        abi: factoryAbi,
        functionName: 'getAddress',
        args: [owner.address, SALT],
      });
      await client.waitForTransactionReceipt({
        hash: await wallet.sendTransaction({
          to: account,
          value: parseEther('1'),
        }),
      });
      assert.equal(await client.getCode({ address: account }), undefined);
      const fees = await client.estimateFeesPerGas();
      const t: Transaction = {
        sender: account,
        nonceKeys: [0n],
        nonce: 0n,
        validUntil: 0,
        overheadGasLimit: 400000n,
        ...fees,
        frames: [
          {
            mode: 0,
            flags: 0,
            target: f,
            gasLimit: 1000000n,
            value: 0n,
            data: encodeFunctionData({
              abi: factoryAbi,
              functionName: 'createAccount',
              args: [owner.address, SALT],
            }),
          },
          {
            mode: 1,
            flags: 3,
            target: zeroAddress,
            gasLimit: 250000n,
            value: 0n,
            data: encodeFunctionData({
              abi: accountAbi,
              functionName: 'validateFrame',
              args: ['0x'],
            }),
          },
          {
            mode: 2,
            flags: 0,
            target,
            gasLimit: 100000n,
            value: 10000n,
            data: '0x',
          },
        ],
        signatures: [
          {
            scheme: 1,
            signer: owner.address,
            message: zeroHash,
            signature: '0x',
          },
        ],
      };
      assert.equal(
        transactionHash(ep, t),
        await client.readContract({
          address: ep,
          abi: vframeAbi,
          functionName: 'getTransactionHash',
          args: [t],
        }),
      );
      t.signatures[0].signature = frameSignature(
        await owner.signTypedData(typedData(ep, t)),
      );
      const originalHash = transactionHash(ep, t);
      assert.equal(
        originalHash,
        await client.readContract({
          address: ep,
          abi: vframeAbi,
          functionName: 'getTransactionHash',
          args: [t],
        }),
      );
      const reordered = {
        ...t,
        frames: [t.frames[1], t.frames[0], t.frames[2]],
      };
      assert.notEqual(originalHash, transactionHash(ep, reordered));
      await assert.rejects(
        client.simulateContract({
          account: owner,
          address: ep,
          abi: vframeAbi,
          functionName: 'handle',
          args: [reordered],
          gas: outerGas(t),
          ...fees,
        }),
      );
      const simulated = await client.simulateContract({
        account: owner,
        address: ep,
        abi: vframeAbi,
        functionName: 'handle',
        args: [t],
        gas: outerGas(t),
        ...fees,
      });
      assert.deepEqual(
        simulated.result.map((r) => r.status),
        [1, 1, 1],
      );
      const receipt = await client.waitForTransactionReceipt({
        hash: await wallet.writeContract({
          address: ep,
          abi: vframeAbi,
          functionName: 'handle',
          args: [t],
          gas: outerGas(t),
          ...fees,
        }),
      });
      assert.equal(receipt.status, 'success');
      assert.equal(await client.getBalance({ address: target }), 10000n);
      assert.equal(
        await client.readContract({
          address: ep,
          abi: vframeAbi,
          functionName: 'nonces',
          args: [account, 0n],
        }),
        1n,
      );
      const events = parseEventLogs({
        abi: vframeAbi,
        logs: receipt.logs.filter(
          (l) => l.address.toLowerCase() === ep.toLowerCase(),
        ),
        eventName: 'FrameResult',
      });
      assert.deepEqual(
        events.map((e) => e.args.status),
        [1, 1, 1],
      );
      assert.ok(
        (await client.readContract({
          address: ep,
          abi: vframeAbi,
          functionName: 'deposits',
          args: [owner.address],
        })) > 0n,
      );
    } finally {
      node.kill('SIGTERM');
      await new Promise<void>((resolve) => node.once('exit', () => resolve()));
    }
  },
);
