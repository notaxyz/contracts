import { readdir, readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const rootDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const deploymentsDir = path.join(rootDir, "deployments");
const addressPattern = /^0x[a-fA-F0-9]{40}$/;
const zeroAddress = "0x0000000000000000000000000000000000000000";
const environments = new Set(["mainnet", "testnet", "local"]);

function isExampleFile(fileName) {
  return fileName.startsWith("example.") || fileName.includes(".example.");
}

function isObject(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isAddress(value) {
  return typeof value === "string" && addressPattern.test(value);
}

const files = (await readdir(deploymentsDir))
  .filter((fileName) => fileName.endsWith(".json"))
  .filter((fileName) => !isExampleFile(fileName))
  .sort();

const errors = [];
const seenChainIds = new Map();

for (const fileName of files) {
  const filePath = path.join(deploymentsDir, fileName);
  const addError = (message) => errors.push(`${fileName}: ${message}`);
  let deployment;

  try {
    deployment = JSON.parse(await readFile(filePath, "utf8"));
  } catch (error) {
    addError(`invalid JSON (${error.message})`);
    continue;
  }

  if (!Number.isInteger(deployment.chainId)) {
    addError("chainId must be an integer number");
  } else if (seenChainIds.has(deployment.chainId)) {
    addError(`chainId duplicates ${seenChainIds.get(deployment.chainId)}`);
  } else {
    seenChainIds.set(deployment.chainId, fileName);
  }

  if (typeof deployment.name !== "string" || deployment.name.length === 0) {
    addError("name must be a non-empty string");
  }

  if (typeof deployment.network !== "string" || deployment.network.length === 0) {
    addError("network must be a non-empty string");
  }

  if (!environments.has(deployment.environment)) {
    addError('environment must be "mainnet", "testnet", or "local"');
  }

  if (!isObject(deployment.contracts)) {
    addError("contracts must be an object");
  } else {
    for (const contractName of ["revealReceiptStore", "purchaseRefRegistry"]) {
      const address = deployment.contracts[contractName];

      if (!isAddress(address)) {
        addError(`contracts.${contractName} must be a 0x address`);
      } else if (address.toLowerCase() === zeroAddress) {
        addError(`contracts.${contractName} must not be the zero address`);
      }
    }
  }

  if (deployment.tokens !== undefined) {
    if (!isObject(deployment.tokens)) {
      addError("tokens must be an object when present");
    } else {
      for (const [symbol, address] of Object.entries(deployment.tokens)) {
        if (!isAddress(address)) {
          addError(`tokens.${symbol} must be a 0x address`);
        } else if (address.toLowerCase() === zeroAddress) {
          addError(`tokens.${symbol} must not be the zero address`);
        }
      }
    }
  }

  if (deployment.startBlock !== undefined && (!Number.isInteger(deployment.startBlock) || deployment.startBlock < 0)) {
    addError("startBlock must be a non-negative integer when present");
  }

  if (deployment.deployedAt !== undefined) {
    if (typeof deployment.deployedAt !== "string" || Number.isNaN(Date.parse(deployment.deployedAt))) {
      addError("deployedAt must be an ISO date string when present");
    }
  }

  if (deployment.version !== undefined && typeof deployment.version !== "string") {
    addError("version must be a string when present");
  }
}

if (errors.length > 0) {
  console.error("Deployment validation failed:");
  for (const error of errors) {
    console.error(`- ${error}`);
  }
  process.exitCode = 1;
} else {
  console.log(`Validated ${files.length} deployment files.`);
}
