export type HexAddress = `0x${string}`;

export type ChainEnvironment = "mainnet" | "testnet" | "local";

export type KnownRevealChainId = 42161 | 421614 | 46630;

export type ChainId = KnownRevealChainId | number;

export type RevealDeploymentContracts = {
  readonly revealReceiptStore: HexAddress;
  readonly purchaseRefRegistry: HexAddress;
  readonly [contractName: string]: HexAddress;
};

export type RevealDeploymentTokens = {
  readonly usdc?: HexAddress;
  readonly usdg?: HexAddress;
  readonly [symbol: string]: HexAddress | undefined;
};

export type RevealDeployment = {
  readonly chainId: number;
  readonly name: string;
  readonly network: string;
  readonly environment: ChainEnvironment;
  readonly contracts: RevealDeploymentContracts;
  readonly tokens?: RevealDeploymentTokens;
  readonly startBlock?: number;
  readonly deployedAt?: string;
  readonly version?: string;
  readonly metadata?: {
    readonly [key: string]: unknown;
  };
  readonly [key: string]: unknown;
};
