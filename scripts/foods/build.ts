/** Turns the CIQUAL XML and the OFF extract into foods.jsonl. See README.md. */
import { createReadStream, createWriteStream, readFileSync } from "node:fs";
import { createInterface } from "node:readline";
import { ciqualFood, offFood, parseCiqualFoods, parseCiqualValues, type OffRow } from "./mapping";

const DATA = "scripts/foods/data";

async function main() {
  const output = createWriteStream(`${DATA}/foods.jsonl`);

  const values = parseCiqualValues(readFileSync(`${DATA}/ciqual/compo.xml`, "utf8"));
  const ciqualFoods = parseCiqualFoods(readFileSync(`${DATA}/ciqual/alim.xml`, "utf8"));
  let ciqualKept = 0;
  for (const { code, nameFr, nameEn } of ciqualFoods) {
    const food = ciqualFood(code, nameFr, nameEn, values.get(code) ?? {});
    if (food) {
      output.write(`${JSON.stringify(food)}\n`);
      ciqualKept += 1;
    }
  }

  let offRead = 0;
  let offKept = 0;
  const seen = new Set<string>();
  const lines = createInterface({ input: createReadStream(`${DATA}/off-france.jsonl`) });
  for await (const line of lines) {
    offRead += 1;
    const food = offFood(JSON.parse(line) as OffRow);
    if (food && !seen.has(food.sourceId)) {
      seen.add(food.sourceId);
      output.write(`${JSON.stringify(food)}\n`);
      offKept += 1;
    }
  }

  await new Promise((resolve) => output.end(resolve));
  console.log(`CIQUAL: kept ${ciqualKept} of ${ciqualFoods.length}`);
  console.log(`OFF: kept ${offKept} of ${offRead}`);
}

main();
