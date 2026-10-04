export const baseChainId = 8453 as const;
export const baseSepoliaChainId = 84532 as const;
export const arbitrumOneChainId = 42161 as const;
export const arbitrumSepoliaChainId = 421614 as const;
export const robinhoodTestnetChainId = 46630 as const;

export const notaSupportedChainIds = [
  baseChainId,
  arbitrumOneChainId,
  arbitrumSepoliaChainId,
  robinhoodTestnetChainId
] as const;

export type NotaSupportedChainId = (typeof notaSupportedChainIds)[number];
