const addressPattern = /^0x[a-fA-F0-9]{40}$/;
const zeroAddress = "0x0000000000000000000000000000000000000000";
const txHashPattern = /^0x[a-fA-F0-9]{64}$/;

const chainMetadata = {
  42161: { name: "arbitrum-one", network: "arbitrum", environment: "mainnet" },
  421614: { name: "arbitrum-sepolia", network: "arbitrum", environment: "testnet" },
  46630: { name: "robinhood-testnet", network: "robinhood", environment: "testnet" },
  8453: { name: "base", network: "base", environment: "mainnet" },
  84532: { name: "base-sepolia", network: "base", environment: "testnet" }
};

export function isExampleFile(fileName) {
  return fileName.startsWith("example.") || fileName.includes(".example.");
}

function isObject(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isAddress(value) {
  return typeof value === "string" && addressPattern.test(value);
}

function isNonZeroAddress(value) {
  return isAddress(value) && value.toLowerCase() !== zeroAddress;
}

function isTxHash(value) {
  return typeof value === "string" && txHashPattern.test(value);
}

function compactObject(value) {
  return Object.fromEntries(Object.entries(value).filter(([, entry]) => entry !== undefined));
}

function contractMetadata(contract) {
  if (!isObject(contract)) {
    return undefined;
  }

  const { address: _address, ...metadata } = contract;
  return Object.keys(metadata).length > 0 ? metadata : undefined;
}

function tokenSymbol(raw) {
  if (typeof raw.settlementTokenSymbol === "string" && raw.settlementTokenSymbol.length > 0) {
    return raw.settlementTokenSymbol.toLowerCase();
  }

  if (raw.chainId === 46630) {
    return "usdg";
  }

  return "usdc";
}

function startBlock(raw) {
  const block = raw.purchaseRefRegistry?.deployBlock;
  return Number.isInteger(block) && block >= 0 ? block : undefined;
}

function normalizedDate(value) {
  if (typeof value !== "string") {
    return undefined;
  }

  const timestamp = Date.parse(value);
  return Number.isNaN(timestamp) ? undefined : new Date(timestamp).toISOString();
}

export function normalizeDeployment(raw, fileName, version) {
  const known = chainMetadata[raw.chainId] ?? {};
  const name = raw.name ?? known.name ?? raw.network ?? fileName.replace(/\.json$/, "");
  const contracts = compactObject({
    purchaseRefRegistry: raw.contracts?.purchaseRefRegistry ?? raw.purchaseRefRegistry?.address,
    notaReceiptStore: raw.contracts?.notaReceiptStore ?? raw.notaReceiptStore?.address,
    revealReceiptStore: raw.contracts?.revealReceiptStore ?? raw.revealReceiptStore?.address
  });

  const tokens = raw.tokens ?? compactObject({
    [tokenSymbol(raw)]: raw.settlementToken
  });

  return compactObject({
    chainId: raw.chainId,
    name,
    network: raw.networkName ?? known.network ?? raw.network,
    environment: raw.environment ?? known.environment,
    contracts,
    tokens,
    startBlock: raw.startBlock ?? startBlock(raw),
    deployedAt: normalizedDate(raw.deployedAt) ?? raw.deployedAt,
    version: raw.version ?? version,
    metadata: compactObject({
      sourceFile: fileName,
      broadcastTimestampMs: raw.broadcastTimestampMs,
      gitCommit: raw.gitCommit,
      deployer: raw.deployer,
      protocolOwner: raw.protocolOwner,
      feeRecipient: raw.feeRecipient,
      protocolFeeBps: raw.protocolFeeBps,
      settlementTokenSymbol: raw.settlementTokenSymbol,
      contracts: compactObject({
        purchaseRefRegistry: contractMetadata(raw.purchaseRefRegistry),
        notaReceiptStore: contractMetadata(raw.notaReceiptStore),
        revealReceiptStore: contractMetadata(raw.revealReceiptStore)
      }),
      registryAuthorization: raw.registryAuthorization
    })
  });
}

export function validateRawDeployment(raw, fileName) {
  const errors = [];
  const addError = (message) => errors.push(`${fileName}: ${message}`);

  if (!isObject(raw)) {
    return [`${fileName}: deployment must be a JSON object`];
  }

  if (!Number.isInteger(raw.chainId)) {
    addError("chainId must be an integer number");
  }

  if (typeof raw.network !== "string" || raw.network.length === 0) {
    addError("network must be a non-empty string");
  }

  if (typeof raw.deployedAt !== "string" || Number.isNaN(Date.parse(raw.deployedAt))) {
    addError("deployedAt must be an ISO date string");
  }

  if (!isNonZeroAddress(raw.settlementToken)) {
    addError("settlementToken must be a non-zero 0x address");
  }

  if (raw.feeRecipient !== undefined && !isAddress(raw.feeRecipient)) {
    addError("feeRecipient must be a 0x address when present");
  }

  if (raw.protocolFeeBps !== undefined && (!Number.isInteger(raw.protocolFeeBps) || raw.protocolFeeBps < 0)) {
    addError("protocolFeeBps must be a non-negative integer when present");
  }

  if (!isObject(raw.purchaseRefRegistry)) {
    addError("purchaseRefRegistry must be an object");
  } else {
    if (!isNonZeroAddress(raw.purchaseRefRegistry.address)) {
      addError("purchaseRefRegistry.address must be a non-zero 0x address");
    }
    if (raw.purchaseRefRegistry.deployTxHash !== undefined && !isTxHash(raw.purchaseRefRegistry.deployTxHash)) {
      addError("purchaseRefRegistry.deployTxHash must be a 0x transaction hash when present");
    }
    if (
      raw.purchaseRefRegistry.deployBlock !== undefined &&
      (!Number.isInteger(raw.purchaseRefRegistry.deployBlock) || raw.purchaseRefRegistry.deployBlock < 0)
    ) {
      addError("purchaseRefRegistry.deployBlock must be a non-negative integer when present");
    }
  }

  const hasNotaReceiptStore = isObject(raw.notaReceiptStore);
  const hasRevealReceiptStore = isObject(raw.revealReceiptStore);

  if (!hasNotaReceiptStore && !hasRevealReceiptStore) {
    addError("one of notaReceiptStore or revealReceiptStore must be present");
  }

  for (const contractName of ["notaReceiptStore", "revealReceiptStore"]) {
    const contract = raw[contractName];

    if (contract === undefined) {
      continue;
    }

    if (!isObject(contract)) {
      addError(`${contractName} must be an object when present`);
      continue;
    }

    if (!isNonZeroAddress(contract.address)) {
      addError(`${contractName}.address must be a non-zero 0x address`);
    }
    if (contract.deployTxHash !== undefined && !isTxHash(contract.deployTxHash)) {
      addError(`${contractName}.deployTxHash must be a 0x transaction hash when present`);
    }
    if (contract.deployBlock !== undefined && (!Number.isInteger(contract.deployBlock) || contract.deployBlock < 0)) {
      addError(`${contractName}.deployBlock must be a non-negative integer when present`);
    }
  }

  return errors;
}

export function validateNormalizedDeployment(deployment, fileName) {
  const errors = [];
  const addError = (message) => errors.push(`${fileName}: normalized ${message}`);

  if (!Number.isInteger(deployment.chainId)) {
    addError("chainId must be an integer number");
  }

  for (const field of ["name", "network"]) {
    if (typeof deployment[field] !== "string" || deployment[field].length === 0) {
      addError(`${field} must be a non-empty string`);
    }
  }

  if (!["mainnet", "testnet", "local"].includes(deployment.environment)) {
    addError('environment must be "mainnet", "testnet", or "local"');
  }

  if (!isObject(deployment.contracts)) {
    addError("contracts must be an object");
  } else {
    if (!isNonZeroAddress(deployment.contracts.purchaseRefRegistry)) {
      addError("contracts.purchaseRefRegistry must be a non-zero 0x address");
    }

    const receiptStoreAddress = deployment.contracts.notaReceiptStore ?? deployment.contracts.revealReceiptStore;
    if (!isNonZeroAddress(receiptStoreAddress)) {
      addError("contracts must include notaReceiptStore or revealReceiptStore as a non-zero 0x address");
    }
  }

  if (deployment.tokens !== undefined) {
    if (!isObject(deployment.tokens)) {
      addError("tokens must be an object when present");
    } else {
      for (const [symbol, address] of Object.entries(deployment.tokens)) {
        if (!isNonZeroAddress(address)) {
          addError(`tokens.${symbol} must be a non-zero 0x address`);
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

  return errors;
}
