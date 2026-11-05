/**
 * Upserts foods.jsonl through foods:importBatch. See README.md.
 * After a failure, resume with: npx tsx scripts/foods/upload.ts <line number it printed>
 */
import { createReadStream } from "node:fs";
import { createInterface } from "node:readline";
import { ConvexHttpClient } from "convex/browser";
import { api } from "../../convex/_generated/api";
import type { ImportDoc } from "../../convex/schema";

const BATCH_SIZE = 500;
const MAX_ATTEMPTS = 4;

async function sendWithRetry(client: ConvexHttpClient, secret: string, docs: ImportDoc[]) {
  for (let attempt = 1; ; attempt += 1) {
    try {
      return await client.mutation(api.foods.importBatch, { secret, docs });
    } catch (error) {
      if (attempt === MAX_ATTEMPTS) throw error;
      await new Promise((resolve) => setTimeout(resolve, 2 ** attempt * 1000));
    }
  }
}

async function main() {
  process.loadEnvFile(".env.local");
  const url = process.env.CONVEX_URL;
  const secret = process.env.FOODS_IMPORT_SECRET;
  if (!url || !secret) throw new Error("Set CONVEX_URL and FOODS_IMPORT_SECRET.");

  const startLine = Number(process.argv[2] ?? 0);
  const client = new ConvexHttpClient(url);
  const totals = { inserted: 0, updated: 0, unchanged: 0 };
  let batch: ImportDoc[] = [];
  let lineNumber = 0;

  const send = async () => {
    try {
      const result = await sendWithRetry(client, secret, batch);
      totals.inserted += result.inserted;
      totals.updated += result.updated;
      totals.unchanged += result.unchanged;
    } catch (error) {
      console.error(`Failed. Resume from line ${lineNumber - batch.length}.`);
      throw error;
    }
    batch = [];
    console.log(`${lineNumber} lines: ${JSON.stringify(totals)}`);
  };

  const lines = createInterface({ input: createReadStream("scripts/foods/data/foods.jsonl") });
  for await (const line of lines) {
    lineNumber += 1;
    if (lineNumber <= startLine) continue;
    batch.push(JSON.parse(line) as ImportDoc);
    if (batch.length === BATCH_SIZE) await send();
  }
  if (batch.length > 0) await send();
  console.log(`Done: ${JSON.stringify(totals)}`);
}

main();
