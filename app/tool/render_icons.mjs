// Renders the app icon sources (assets/icon/*.svg) to PNG, plus the multi-size
// Windows .ico. Uses headless Chromium through Playwright, so the SVGs render
// exactly as a browser draws them.
//
//   cd app/tool
//   npm i --no-save playwright && npx playwright install chromium
//   node render_icons.mjs
//   cd .. && dart run flutter_launcher_icons     # Android + iOS sizes
import { chromium } from "playwright";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const app = join(dirname(fileURLToPath(import.meta.url)), "..");
const icons = join(app, "assets/icon");
const pngs = ["icon", "icon_background", "icon_foreground", "icon_monochrome", "icon_desktop"];
const icoSizes = [16, 24, 32, 48, 64, 128, 256];

const browser = await chromium.launch();

async function render(name, size) {
  const svg = readFileSync(join(icons, `${name}.svg`), "utf8")
    .replace(/width="1024" height="1024"/, 'width="100%" height="100%"');
  const page = await browser.newPage({ viewport: { width: size, height: size } });
  await page.setContent(
    `<html><body style="margin:0;background:transparent">` +
      `<div style="width:${size}px;height:${size}px">${svg}</div></body></html>`,
  );
  const png = await page.locator("div").screenshot({ omitBackground: true });
  await page.close();
  return png;
}

for (const name of pngs) {
  writeFileSync(join(icons, `${name}.png`), await render(name, 1024));
  console.log(`assets/icon/${name}.png`);
}

// ICO with PNG-compressed entries (supported since Windows Vista).
const images = [];
for (const s of icoSizes) images.push(await render("icon_desktop", s));
const head = Buffer.alloc(6 + 16 * icoSizes.length);
head.writeUInt16LE(1, 2); // type: icon
head.writeUInt16LE(icoSizes.length, 4);
let offset = head.length;
icoSizes.forEach((s, i) => {
  const e = 6 + 16 * i;
  head.writeUInt8(s >= 256 ? 0 : s, e); // 0 means 256
  head.writeUInt8(s >= 256 ? 0 : s, e + 1);
  head.writeUInt16LE(1, e + 4); // planes
  head.writeUInt16LE(32, e + 6); // bits per pixel
  head.writeUInt32LE(images[i].length, e + 8);
  head.writeUInt32LE(offset, e + 12);
  offset += images[i].length;
});
writeFileSync(join(app, "windows/runner/resources/app_icon.ico"), Buffer.concat([head, ...images]));
console.log("windows/runner/resources/app_icon.ico");

await browser.close();
