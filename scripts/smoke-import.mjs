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

check(Array.isArray(pkg.notaReceiptStoreAbi), "notaReceiptStoreAbi must be an array");
check(pkg.notaReceiptStoreAbi?.length > 0, "notaReceiptStoreAbi must not be empty");
check(Array.isArray(pkg.revealReceiptStoreAbi), "revealReceiptStoreAbi must be an array");
check(pkg.revealReceiptStoreAbi?.length > 0, "revealReceiptStoreAbi must not be empty");
check(Array.isArray(pkg.purchaseRefRegistryAbi), "purchaseRefRegistryAbi must be an array");
check(pkg.purchaseRefRegistryAbi?.length > 0, "purchaseRefRegistryAbi must not be empty");

const receiptEvent = pkg.notaReceiptStoreAbi?.find((item) => item.type === "event" && item.name === "ReceiptPurchasedV2");
check(Boolean(receiptEvent), "notaReceiptStoreAbi must include ReceiptPurchasedV2");
check(receiptEvent?.inputs?.some((input) => input.name === "agentId"), "ReceiptPurchasedV2 must include agentId");
check(
  receiptEvent?.inputs?.filter((input) => input.indexed).map((input) => input.name).join(",") ===
    "seller,buyer,purchaseRef",
  "ReceiptPurchasedV2 must index seller, buyer, and purchaseRef"
);

const purchaseSignedReceipt = pkg.notaReceiptStoreAbi?.find(
  (item) => item.type === "function" && item.name === "purchaseSignedReceipt"
);
const signedQuote = purchaseSignedReceipt?.inputs?.find((input) => input.name === "quote");
check(signedQuote?.components?.some((input) => input.name === "agentId"), "SignedReceiptQuote must include agentId");
check(
  purchaseSignedReceipt?.inputs?.some((input) => input.name === "claimedSigner"),
  "purchaseSignedReceipt must include claimedSigner"
);

const validateSignedReceiptPurchase = pkg.notaReceiptStoreAbi?.find(
  (item) => item.type === "function" && item.name === "validateSignedReceiptPurchase"
);
check(
  validateSignedReceiptPurchase?.inputs?.some((input) => input.name === "claimedSigner"),
  "validateSignedReceiptPurchase must include claimedSigner"
);
check(
  validateSignedReceiptPurchase?.outputs?.length === 1 && validateSignedReceiptPurchase.outputs[0].type === "tuple",
  "validateSignedReceiptPurchase must return one struct"
);

for (const removedGetter of ["getReceipt", "getReceiptIdBySellerAndPurchaseRef", "receipts"]) {
  check(
    !pkg.notaReceiptStoreAbi?.some((item) => item.type === "function" && item.name === removedGetter),
    `notaReceiptStoreAbi must not include removed ${removedGetter} getter`
  );
}

const legacyReceiptGetter = pkg.revealReceiptStoreAbi?.find((item) => item.type === "function" && item.name === "receipts");
check(Boolean(legacyReceiptGetter), "revealReceiptStoreAbi must include legacy receipts getter");

check(typeof pkg.getDeployment === "function", "getDeployment must be a function");
check(typeof pkg.hasDeployment === "function", "hasDeployment must be a function");
check(typeof pkg.getReceiptStoreAddress === "function", "getReceiptStoreAddress must be a function");
check(typeof pkg.deployments === "object" && pkg.deployments !== null, "deployments must be an object");
check(Array.isArray(pkg.notaSupportedChainIds), "notaSupportedChainIds must be an array");
check(pkg.notaSupportedChainIds?.includes(8453), "notaSupportedChainIds must include Base chainId 8453");

check(pkg.hasDeployment?.(42161) === true, "hasDeployment(42161) must return true");
check(pkg.hasDeployment?.(8453) === true, "hasDeployment(8453) must return true");

const addressPattern = /^0x[a-fA-F0-9]{40}$/;
const baseDeployment = pkg.getDeployment?.(8453);

check(baseDeployment?.chainId === 8453, "getDeployment(8453).chainId must be 8453");
check(
  addressPattern.test(baseDeployment?.contracts?.notaReceiptStore ?? ""),
  "getDeployment(8453).contracts.notaReceiptStore must be a 0x address"
);
check(
  addressPattern.test(baseDeployment?.contracts?.purchaseRefRegistry ?? ""),
  "getDeployment(8453).contracts.purchaseRefRegistry must be a 0x address"
);
check(addressPattern.test(pkg.getReceiptStoreAddress?.(8453) ?? ""), "getReceiptStoreAddress(8453) must return an address");

const legacyDeployment = pkg.getDeployment?.(42161);

check(legacyDeployment?.chainId === 42161, "getDeployment(42161).chainId must be 42161");
check(
  addressPattern.test(legacyDeployment?.contracts?.revealReceiptStore ?? ""),
  "getDeployment(42161).contracts.revealReceiptStore must be a 0x address"
);
check(
  addressPattern.test(legacyDeployment?.contracts?.purchaseRefRegistry ?? ""),
  "getDeployment(42161).contracts.purchaseRefRegistry must be a 0x address"
);
check(addressPattern.test(pkg.getReceiptStoreAddress?.(42161) ?? ""), "getReceiptStoreAddress(42161) must return an address");

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
