export type HexAddress = `0x${string}`;

export type ChainEnvironment = "mainnet" | "testnet" | "local";

export type KnownNotaChainId = 8453 | 84532 | 42161 | 421614 | 46630;

export type ChainId = KnownNotaChainId | number;

type NotaReceiptStoreContracts = {
  readonly notaReceiptStore: HexAddress;
  readonly revealReceiptStore?: HexAddress;
};

type LegacyRevealReceiptStoreContracts = {
  readonly revealReceiptStore: HexAddress;
  readonly notaReceiptStore?: HexAddress;
};

export type NotaDeploymentContracts = (NotaReceiptStoreContracts | LegacyRevealReceiptStoreContracts) & {
  readonly purchaseRefRegistry: HexAddress;
  readonly [contractName: string]: HexAddress | undefined;
};

export type NotaDeploymentTokens = {
  readonly usdc?: HexAddress;
  readonly usdg?: HexAddress;
  readonly [symbol: string]: HexAddress | undefined;
};

export type NotaDeployment = {
  readonly chainId: number;
  readonly name: string;
  readonly network: string;
  readonly environment: ChainEnvironment;
  readonly contracts: NotaDeploymentContracts;
  readonly tokens?: NotaDeploymentTokens;
  readonly startBlock?: number;
  readonly deployedAt?: string;
  readonly version?: string;
  readonly metadata?: {
    readonly [key: string]: unknown;
  };
  readonly [key: string]: unknown;
};
