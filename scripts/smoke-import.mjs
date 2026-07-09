import { existsSync } from "node:fs";
import path from "node:path";
import { pathToFileURL, fileURLToPath } from "node:url";

const rootDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const distEntry = pathToFileURL(path.join(rootDir, "dist", "index.js")).href;

const requiredDistFiles = [
  "dist/index.js",
  "dist/index.d.ts",
  "dist/abis.js",
  "dist/abis.generated.js",
  "dist/abis.generated.d.ts",
  "dist/deployments.js",
  "dist/deployments.generated.js",
  "dist/deployments.generated.d.ts",
  "dist/chains.js",
  "dist/types.js"
];

const missingDistFiles = requiredDistFiles.filter((file) => !existsSync(path.join(rootDir, file)));

if (missingDistFiles.length > 0) {
  console.error("Smoke import failed: dist/ is incomplete. Missing files:");
  for (const file of missingDistFiles) {
    console.error(`- ${file}`);
  }
  console.error("Run `npm run build` first.");
  process.exit(1);
}

const errors = [];

function check(condition, message) {
  if (!condition) {
    errors.push(message);
  }
}

let pkg;

try {
  pkg = await import(distEntry);
} catch (error) {
  console.error(`Smoke import failed: could not import dist/index.js (${error.message})`);
  console.error("Run `npm run build` first.");
  process.exit(1);
}

check(Array.isArray(pkg.revealReceiptStoreAbi), "revealReceiptStoreAbi must be an array");
check(pkg.revealReceiptStoreAbi?.length > 0, "revealReceiptStoreAbi must not be empty");
check(Array.isArray(pkg.purchaseRefRegistryAbi), "purchaseRefRegistryAbi must be an array");
check(pkg.purchaseRefRegistryAbi?.length > 0, "purchaseRefRegistryAbi must not be empty");

check(typeof pkg.getDeployment === "function", "getDeployment must be a function");
check(typeof pkg.hasDeployment === "function", "hasDeployment must be a function");
check(typeof pkg.deployments === "object" && pkg.deployments !== null, "deployments must be an object");
check(Array.isArray(pkg.revealSupportedChainIds), "revealSupportedChainIds must be an array");
check(pkg.revealSupportedChainIds?.includes(42161), "revealSupportedChainIds must include 42161");

check(pkg.hasDeployment?.(42161) === true, "hasDeployment(42161) must return true");

const deployment = pkg.getDeployment?.(42161);
const addressPattern = /^0x[a-fA-F0-9]{40}$/;

check(deployment?.chainId === 42161, "getDeployment(42161).chainId must be 42161");
check(addressPattern.test(deployment?.contracts?.revealReceiptStore ?? ""), "getDeployment(42161).contracts.revealReceiptStore must be a 0x address");
check(addressPattern.test(deployment?.contracts?.purchaseRefRegistry ?? ""), "getDeployment(42161).contracts.purchaseRefRegistry must be a 0x address");

check(pkg.hasDeployment?.(999999999) === false, "hasDeployment(999999999) must return false");

let threwForUnknownChain = false;
try {
  pkg.getDeployment?.(999999999);
} catch {
  threwForUnknownChain = true;
}
check(threwForUnknownChain, "getDeployment(999999999) must throw");

if (errors.length > 0) {
  console.error("Smoke import failed:");
  for (const error of errors) {
    console.error(`- ${error}`);
  }
  process.exit(1);
}

console.log("Smoke import passed: ABIs, deployments, chains, and helpers all resolve from dist/.");
