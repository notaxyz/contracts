import type { HexAddress, NotaDeployment } from "./types.js";
import { deployments as generatedDeployments } from "./deployments.generated.js";

export const deployments = generatedDeployments;

const deploymentByChainId: Readonly<Record<number, NotaDeployment>> = generatedDeployments;

export function getDeployment(chainId: number): NotaDeployment {
  const deployment = deploymentByChainId[chainId];

  if (!deployment) {
    throw new Error(`Nota deployment not found for chainId ${chainId}`);
  }

  return deployment;
}

export function hasDeployment(chainId: number): boolean {
  return Boolean(deploymentByChainId[chainId]);
}

export function getReceiptStoreAddress(chainId: number): HexAddress;
export function getReceiptStoreAddress(deployment: NotaDeployment): HexAddress;
export function getReceiptStoreAddress(input: number | NotaDeployment): HexAddress {
  const deployment = typeof input === "number" ? getDeployment(input) : input;
  const receiptStore = deployment.contracts.notaReceiptStore ?? deployment.contracts.revealReceiptStore;

  if (!receiptStore) {
    throw new Error(`Nota receipt store not found for chainId ${deployment.chainId}`);
  }

  return receiptStore;
}
