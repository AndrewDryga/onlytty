// Render the Open Graph card (dev/brand/og.html) → portal/priv/static/assets/og.png.
// Reproducible replacement for the old hand-export. Run from the repo root:
//   node dev/brand/og-render.mjs
// Renders at 2× for crisp text, downscales to 1200×630 with sips, then optimizes
// with pngquant + oxipng if they're installed (skips gracefully if not).
import { chromium } from "playwright";
import { execSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { existsSync } from "node:fs";

const here = dirname(fileURLToPath(import.meta.url));
const src = resolve(here, "og.html");
const out = resolve(here, "../../portal/priv/static/assets/og.png");
const tmp = "/tmp/og-onlytty-2x.png";

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1200, height: 630 }, deviceScaleFactor: 2 });
await page.goto("file://" + src, { waitUntil: "networkidle" });
await page.screenshot({ path: tmp, clip: { x: 0, y: 0, width: 1200, height: 630 } });
await browser.close();

// 2× (2400×1260) → exact 1200×630, supersampled for crisp text.
execSync(`sips -z 630 1200 ${tmp} --out ${out}`, { stdio: "ignore" });

const has = (bin) => { try { execSync(`command -v ${bin}`, { stdio: "ignore" }); return true; } catch { return false; } };
if (has("pngquant")) execSync(`pngquant --quality=80-96 --strip --force --output ${out} ${out}`, { stdio: "ignore" });
if (has("oxipng")) execSync(`oxipng -o6 --strip safe ${out}`, { stdio: "ignore" });

const size = existsSync(out) ? execSync(`wc -c < ${out}`).toString().trim() : "?";
console.log(`wrote ${out} (${size} bytes)`);
