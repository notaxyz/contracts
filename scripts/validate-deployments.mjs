import { readdir, readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  isExampleFile,
  normalizeDeployment,
  validateNormalizedDeployment,
  validateRawDeployment
} from "./deployment-utils.mjs";

const rootDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const deploymentsDir = path.join(rootDir, "deployments");
const packageJson = JSON.parse(await readFile(path.join(rootDir, "package.json"), "utf8"));

const files = (await readdir(deploymentsDir))
  .filter((fileName) => fileName.endsWith(".json"))
  .filter((fileName) => !isExampleFile(fileName))
  .sort();

const errors = [];
const seenChainIds = new Map();

for (const fileName of files) {
  const filePath = path.join(deploymentsDir, fileName);
  let rawDeployment;

  try {
    rawDeployment = JSON.parse(await readFile(filePath, "utf8"));
  } catch (error) {
    errors.push(`${fileName}: invalid JSON (${error.message})`);
    continue;
  }

  errors.push(...validateRawDeployment(rawDeployment, fileName));

  if (Number.isInteger(rawDeployment.chainId)) {
    if (seenChainIds.has(rawDeployment.chainId)) {
      errors.push(`${fileName}: chainId duplicates ${seenChainIds.get(rawDeployment.chainId)}`);
    } else {
      seenChainIds.set(rawDeployment.chainId, fileName);
    }
  }

  const normalizedDeployment = normalizeDeployment(rawDeployment, fileName, packageJson.version);
  errors.push(...validateNormalizedDeployment(normalizedDeployment, fileName));
}

if (errors.length > 0) {
  console.error("Deployment validation failed:");
  for (const error of errors) {
    console.error(`- ${error}`);
  }
  process.exitCode = 1;
} else {
  console.log(`Validated ${files.length} raw deployment files and generated package shapes.`);
}
