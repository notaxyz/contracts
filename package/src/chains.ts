export const arbitrumOneChainId = 42161 as const;
export const arbitrumSepoliaChainId = 421614 as const;
export const robinhoodTestnetChainId = 46630 as const;

export const revealSupportedChainIds = [
  arbitrumOneChainId,
  arbitrumSepoliaChainId,
  robinhoodTestnetChainId
] as const;

export type RevealSupportedChainId = (typeof revealSupportedChainIds)[number];
