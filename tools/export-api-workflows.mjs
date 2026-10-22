// Convert ComfyUI UI-format workflows to API format with ComfyUI's own
// exporter (app.graphToPrompt — what "Export (API)" runs), driven headless
// against a live ComfyUI that has every node pack installed (e.g. the
// Hearmeman comfyui-minimax pod through the RunPod proxy).
//
//   npm i playwright-core@1.48.2
//   node tools/export-api-workflows.mjs <comfy url> <out dir> <workflow.json>...
//
// CHROME=/path/to/chrome overrides the browser (default: google-chrome).
import { chromium } from "playwright-core";
import fs from "node:fs";
import path from "node:path";

const [url, outDir, ...files] = process.argv.slice(2);
if (!url || !outDir || !files.length) {
  console.error("usage: export-api-workflows.mjs <comfy url> <out dir> <workflow.json>...");
  process.exit(2);
}
fs.mkdirSync(outDir, { recursive: true });

const browser = await chromium.launch({
  executablePath: process.env.CHROME || "/usr/bin/google-chrome",
  headless: false, args: ["--headless=new"],  // Chrome dropped the old headless mode
});
const page = await browser.newPage();
page.on("dialog", (d) => d.dismiss());
await page.goto(url, { waitUntil: "domcontentloaded", timeout: 120000 });
await page.waitForFunction(() => window.app?.graph && window.app?.graphToPrompt, null, { timeout: 180000 });

let failed = 0;
for (const file of files) {
  const name = path.basename(file);
  try {
    const graph = JSON.parse(fs.readFileSync(file, "utf8"));
    const res = await page.evaluate(async ({ graph, name }) => {
      await window.app.loadGraphData(graph, true, false, name);
      const { output } = await window.app.graphToPrompt();
      return output;
    }, { graph, name });
    if (!res || !Object.keys(res).length) throw new Error("empty export");
    fs.writeFileSync(path.join(outDir, name), JSON.stringify(res, null, 2) + "\n");
    console.log(`ok   ${name} (${Object.keys(res).length} nodes)`);
  } catch (e) {
    failed++;
    console.error(`FAIL ${name}: ${e.message.split("\n")[0]}`);
  }
}
await browser.close();
process.exit(failed ? 1 : 0);
