import { createPublicClient, http } from "viem";
import { arbitrum } from "viem/chains";
import { getDeployment, revealReceiptStoreAbi } from "@reveal-protocol/contracts";

const deployment = getDeployment(arbitrum.id);

const client = createPublicClient({
  chain: arbitrum,
  transport: http(process.env.ARBITRUM_RPC_URL)
});

const receiptId = 1n;

const receipt = await client.readContract({
  address: deployment.contracts.revealReceiptStore,
  abi: revealReceiptStoreAbi,
  functionName: "receipts",
  args: [receiptId]
});

console.log(receipt);
