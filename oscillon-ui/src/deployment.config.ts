/**
 * Single source of truth for contract addresses in the frontend.
 * `deployment.json` is written automatically by `script/DeployOscillon.s.sol`
 * as a chain-keyed registry: `{ "31337": { ... }, "421614": { ... } }`.
 */

import deploymentJson from "./deployment.json";

export interface Deployment {
  chainId: number;
  chainName: string;
  deployedAt: string;
  deployer: `0x${string}`;
  poolManager: `0x${string}`;
  swapRouter: `0x${string}`;
  liquidityRouter: `0x${string}`;
  oscillonHook: `0x${string}`;
  usdc: `0x${string}`;
  usdt: `0x${string}`;
  chainlinkFeed0: `0x${string}`;
  chainlinkFeed1: `0x${string}`;
  chainlinkAdapter0: `0x${string}`;
  chainlinkAdapter1: `0x${string}`;
  oracle0: `0x${string}`;
  oracle1: `0x${string}`;
  poolCurrency0: `0x${string}`;
  poolCurrency1: `0x${string}`;
  poolFee: number;
  poolTickSpacing: number;
  poolHooks: `0x${string}`;
  poolId: `0x${string}`;
}

/** Chain-keyed deployments written by `DeployOscillon.s.sol`. */
export type DeploymentRegistry = Record<string, Deployment>;

export const deployments = deploymentJson as DeploymentRegistry;

export const DEFAULT_CHAIN_ID = 31337;

/**
 * Sepolia (11155111) is a multi-pool deployment: 3 pools (USDC/USDT,
 * USDe/USDC, USDe/USDT) sharing 3 tokens/adapters, written by
 * DeployOscillon.s.sol's `_writeMultiPoolDeploymentJson`. Distinct shape
 * from the single-pool `Deployment` above — do not conflate the two.
 */
export interface MultiPoolDeployment {
  chainId: number;
  chainName: string;
  deployedAt: string;
  deployer: `0x${string}`;
  poolManager: `0x${string}`;
  swapRouter: `0x${string}`;
  liquidityRouter: `0x${string}`;
  oscillonHook: `0x${string}`;
  usde: `0x${string}`;
  usdc: `0x${string}`;
  usdt: `0x${string}`;
  usdeAdapter: `0x${string}`;
  usdcAdapter: `0x${string}`;
  usdtAdapter: `0x${string}`;
  usdeFeed: `0x${string}`;
  usdcFeed: `0x${string}`;
  usdtFeed: `0x${string}`;
  usdcUsdt_currency0: `0x${string}`;
  usdcUsdt_currency1: `0x${string}`;
  usdcUsdt_poolId: `0x${string}`;
  usdeUsdc_currency0: `0x${string}`;
  usdeUsdc_currency1: `0x${string}`;
  usdeUsdc_poolId: `0x${string}`;
  usdeUsdt_currency0: `0x${string}`;
  usdeUsdt_currency1: `0x${string}`;
  usdeUsdt_poolId: `0x${string}`;
}

export const SEPOLIA_CHAIN_ID = 11155111;
const POOL_FEE = 8388608; // LPFeeLibrary.DYNAMIC_FEE_FLAG
const POOL_TICK_SPACING = 1;

export function getMultiPoolDeployment(
  chainId: number = SEPOLIA_CHAIN_ID,
): MultiPoolDeployment {
  const d = (deploymentJson as Record<string, unknown>)[String(chainId)];
  if (!d) {
    throw new Error(`No multi-pool deployment found for chain ${chainId}`);
  }
  return d as MultiPoolDeployment;
}

export type SepoliaPoolName = "usdcUsdt" | "usdeUsdc" | "usdeUsdt";

/** Returns the 3 Sepolia pools as ready-to-use PoolKey + poolId pairs. */
export function getSepoliaPools(): Record<
  SepoliaPoolName,
  {
    poolKey: {
      currency0: `0x${string}`;
      currency1: `0x${string}`;
      fee: number;
      tickSpacing: number;
      hooks: `0x${string}`;
    };
    poolId: `0x${string}`;
  }
> {
  const d = getMultiPoolDeployment(SEPOLIA_CHAIN_ID);
  const make = (currency0: `0x${string}`, currency1: `0x${string}`) => ({
    currency0,
    currency1,
    fee: POOL_FEE,
    tickSpacing: POOL_TICK_SPACING,
    hooks: d.oscillonHook,
  });
  return {
    usdcUsdt: {
      poolKey: make(d.usdcUsdt_currency0, d.usdcUsdt_currency1),
      poolId: d.usdcUsdt_poolId,
    },
    usdeUsdc: {
      poolKey: make(d.usdeUsdc_currency0, d.usdeUsdc_currency1),
      poolId: d.usdeUsdc_poolId,
    },
    usdeUsdt: {
      poolKey: make(d.usdeUsdt_currency0, d.usdeUsdt_currency1),
      poolId: d.usdeUsdt_poolId,
    },
  };
}

const EMPTY_DEPLOYMENT: Deployment = {
  chainId: 0,
  chainName: "",
  deployedAt: "0",
  deployer: "0x0000000000000000000000000000000000000000",
  poolManager: "0x0000000000000000000000000000000000000000",
  swapRouter: "0x0000000000000000000000000000000000000000",
  liquidityRouter: "0x0000000000000000000000000000000000000000",
  oscillonHook: "0x0000000000000000000000000000000000000000",
  usdc: "0x0000000000000000000000000000000000000000",
  usdt: "0x0000000000000000000000000000000000000000",
  chainlinkFeed0: "0x0000000000000000000000000000000000000000",
  chainlinkFeed1: "0x0000000000000000000000000000000000000000",
  chainlinkAdapter0: "0x0000000000000000000000000000000000000000",
  chainlinkAdapter1: "0x0000000000000000000000000000000000000000",
  oracle0: "0x0000000000000000000000000000000000000000",
  oracle1: "0x0000000000000000000000000000000000000000",
  poolCurrency0: "0x0000000000000000000000000000000000000000",
  poolCurrency1: "0x0000000000000000000000000000000000000000",
  poolFee: 8388608,
  poolTickSpacing: 1,
  poolHooks: "0x0000000000000000000000000000000000000000",
  poolId: "0x0000000000000000000000000000000000000000000000000000000000000000",
};

export function getDeployment(chainId: number = DEFAULT_CHAIN_ID): Deployment {
  return deployments[String(chainId)] ?? EMPTY_DEPLOYMENT;
}

/** @deprecated Prefer `getDeployment(chainId)` when the wallet chain is known. */
export const deployment = getDeployment(DEFAULT_CHAIN_ID);

export function getHookAddress(chainId: number = DEFAULT_CHAIN_ID) {
  return getDeployment(chainId).oscillonHook;
}

export function getPoolKey(chainId: number = DEFAULT_CHAIN_ID) {
  const d = getDeployment(chainId);
  return {
    currency0: d.poolCurrency0,
    currency1: d.poolCurrency1,
    fee: d.poolFee,
    tickSpacing: d.poolTickSpacing,
    hooks: d.poolHooks,
  } as const;
}

export const HOOK_ADDRESS = deployment.oscillonHook;
export const PM_ADDRESS = deployment.poolManager;
export const SWAP_ROUTER_ADDRESS = deployment.swapRouter;
export const LIQUIDITY_ROUTER_ADDRESS = deployment.liquidityRouter;
export const USDC_ADDRESS = deployment.usdc;
export const USDT_ADDRESS = deployment.usdt;
export const POOL_ID = deployment.poolId;

export const POOL_KEY = getPoolKey(DEFAULT_CHAIN_ID);

export const HOOK_ABI = [
  {
    name: "getPoolState",
    type: "function",
    stateMutability: "view",
    inputs: [
      {
        name: "key",
        type: "tuple",
        components: [
          { name: "currency0", type: "address" },
          { name: "currency1", type: "address" },
          { name: "fee", type: "uint24" },
          { name: "tickSpacing", type: "int24" },
          { name: "hooks", type: "address" },
        ],
      },
    ],
    outputs: [
      { name: "registered", type: "bool" },
      { name: "depegBps0", type: "uint256" },
      { name: "pegBelow0", type: "bool" },
      { name: "usingFallback0", type: "bool" },
      { name: "depegBps1", type: "uint256" },
      { name: "pegBelow1", type: "bool" },
      { name: "usingFallback1", type: "bool" },
      { name: "inRestoreWindow", type: "bool" },
      { name: "surplusAccrued", type: "uint256" },
      { name: "protocolAccrued", type: "uint256" },
      { name: "twapWarmedUp", type: "bool" },
    ],
  },
  {
    name: "getPoolConfig",
    type: "function",
    stateMutability: "view",
    inputs: [
      {
        name: "key",
        type: "tuple",
        components: [
          { name: "currency0", type: "address" },
          { name: "currency1", type: "address" },
          { name: "fee", type: "uint24" },
          { name: "tickSpacing", type: "int24" },
          { name: "hooks", type: "address" },
        ],
      },
    ],
    outputs: [
      {
        name: "",
        type: "tuple",
        components: [
          { name: "registered", type: "bool" },
          { name: "token0", type: "address" },
          { name: "token1", type: "address" },
          { name: "maxDepegSwap0", type: "uint256" },
          { name: "maxDepegSwap1", type: "uint256" },
          { name: "lastHighDepegAt", type: "uint256" },
          { name: "surplusAccrued", type: "uint256" },
          { name: "protocolAccrued", type: "uint256" },
        ],
      },
    ],
  },
  {
    name: "DepegDetected",
    type: "event",
    inputs: [
      { name: "poolId", type: "bytes32", indexed: true },
      { name: "depegBps", type: "uint256", indexed: false },
      { name: "feeApplied", type: "uint24", indexed: false },
      { name: "swapSize", type: "uint256", indexed: false },
      { name: "isDrain", type: "bool", indexed: false },
      { name: "usingFallback", type: "bool", indexed: false },
      { name: "twapWarmedUp", type: "bool", indexed: false },
      { name: "tokenInIsToken0", type: "bool", indexed: false },
    ],
  },
  {
    name: "PoolRegistered",
    type: "event",
    inputs: [
      { name: "poolId", type: "bytes32", indexed: true },
      { name: "token0", type: "address", indexed: false },
      { name: "token1", type: "address", indexed: false },
      { name: "chainlink0", type: "address", indexed: false },
      { name: "chainlink1", type: "address", indexed: false },
    ],
  },
] as const;

export const ERC20_ABI = [
  {
    name: "approve",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "spender", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    name: "balanceOf",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    name: "allowance",
    type: "function",
    stateMutability: "view",
    inputs: [
      { name: "owner", type: "address" },
      { name: "spender", type: "address" },
    ],
    outputs: [{ name: "", type: "uint256" }],
  },
] as const;

export const ANVIL_CHAIN = {
  id: 31337,
  name: "Anvil",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["http://127.0.0.1:8545"] } },
} as const;

export const ARBITRUM_SEPOLIA_CHAIN = {
  id: 421614,
  name: "Arbitrum Sepolia",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["https://sepolia-rollup.arbitrum.io/rpc"] } },
  blockExplorers: {
    default: { name: "Arbiscan", url: "https://sepolia.arbiscan.io" },
  },
} as const;

export const ETHEREUM_SEPOLIA_CHAIN = {
  id: 11155111,
  name: "Ethereum Sepolia",
  nativeCurrency: { name: "Sepolia Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["https://ethereum-sepolia-rpc.publicnode.com"] } },
  blockExplorers: {
    default: { name: "Etherscan", url: "https://sepolia.etherscan.io" },
  },
} as const;

export function getChainConfig(chainId: number = DEFAULT_CHAIN_ID) {
  switch (chainId) {
    case 31337:
      return ANVIL_CHAIN;
    case 421614:
      return ARBITRUM_SEPOLIA_CHAIN;
    case 11155111:
      return ETHEREUM_SEPOLIA_CHAIN;
    default:
      return ANVIL_CHAIN;
  }
}

export function isDeployed(chainId: number = DEFAULT_CHAIN_ID): boolean {
  const d = getDeployment(chainId);
  return (
    d.chainId !== 0 &&
    d.oscillonHook !== "0x0000000000000000000000000000000000000000"
  );
}

export function formatDepeg(depegBps: bigint): string {
  const bps = Number(depegBps);
  if (bps === 0) return "At parity ($1.00)";
  if (bps < 7) return `${bps} bps (micro-depeg)`;
  if (bps < 30) return `${bps} bps (active depeg)`;
  return `${bps} bps (SEVERE depeg)`;
}

export function formatFee(feePips: number): string {
  return `${(feePips / 100).toFixed(2)} bps`;
}

export function formatUSD(amount: bigint, decimals = 6): string {
  return `$${(Number(amount) / 10 ** decimals).toLocaleString("en-US", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  })}`;
}
