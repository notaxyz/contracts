import type { RevealDeployment } from "./types.js";
import { deployments as generatedDeployments } from "./deployments.generated.js";

export const deployments = generatedDeployments;
const deploymentByChainId: Readonly<Record<number, RevealDeployment>> = generatedDeployments;

export function getDeployment(chainId: number): RevealDeployment {
  const deployment = deploymentByChainId[chainId];

  if (!deployment) {
    throw new Error(`Reveal deployment not found for chainId ${chainId}`);
  }

  return deployment;
}

export function hasDeployment(chainId: number): boolean {
  return Boolean(deploymentByChainId[chainId]);
}
