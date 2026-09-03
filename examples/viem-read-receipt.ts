import { createPublicClient, http } from "viem";
import { base } from "viem/chains";
import { getDeployment, getReceiptStoreAddress, notaReceiptStoreAbi } from "@notaxyz/contracts";

const deployment = getDeployment(base.id);

const client = createPublicClient({
  chain: base,
  transport: http()
});

if (deployment.startBlock === undefined) {
  throw new Error("The Base deployment is missing its start block.");
}

const receipts = await client.getContractEvents({
  address: getReceiptStoreAddress(deployment),
  abi: notaReceiptStoreAbi,
  eventName: "ReceiptPurchasedV2",
  fromBlock: BigInt(deployment.startBlock)
});

console.log(receipts.at(-1) ?? "No ReceiptPurchasedV2 events found.");
