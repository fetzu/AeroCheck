// Smaller WebP copies of every screenshot, for the pages' `srcset` (src/lib/shots.ts). Runs before `astro dev` and
// `astro build` (npm's predev/prebuild), so the copies are never committed: public/_shots/ is in .gitignore.
//
// Why (3 Nov 2026): the home page asked for 4.3 MB of full-size JPEGs, the 1200 px iPad shots on a phone too, where
// they show about 250 px wide. Each copy keeps the folder and name of its JPEG, plus its width:
// public/assets/screenshot/v6/ipad/route.jpg → public/_shots/v6/ipad/route-360.webp, -720 and -1200.
//
// A copy newer than its JPEG is kept, so a second run takes a second; a copy whose JPEG is gone is deleted.
import { mkdirSync, readdirSync, rmSync, statSync } from 'node:fs';
import { dirname, join, relative } from 'node:path';
import sharp from 'sharp';

const SOURCE = 'public/assets/screenshot';
const OUT = 'public/_shots';
// The widths a browser picks from: a phone at 3x needs about 800 px of the iPad shot, a desktop at 2x about 1000.
// One within 15% of the full width is left out, the full width takes its place.
const LADDER = [360, 720, 1080];
const QUALITY = 80;

function walk(dir, ext) {
  let found = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) found = found.concat(walk(path, ext));
    else if (entry.name.endsWith(ext)) found.push(path);
  }
  return found;
}

const mtime = (path) => { try { return statSync(path).mtimeMs; } catch { return 0; } };

const started = Date.now();
const wanted = new Set();
let made = 0;
for (const jpg of walk(SOURCE, '.jpg')) {
  const { width } = await sharp(jpg).metadata();
  const widths = [...LADDER.filter((w) => w < width * 0.85), width];
  const stem = join(OUT, relative(SOURCE, jpg)).replace(/\.jpg$/, '');
  mkdirSync(dirname(stem), { recursive: true });
  for (const w of widths) {
    const out = `${stem}-${w}.webp`;
    wanted.add(out);
    if (mtime(out) > mtime(jpg)) continue;
    await sharp(jpg).resize({ width: w }).webp({ quality: QUALITY }).toFile(out);
    made++;
  }
}

let removed = 0;
for (const webp of (statSync(OUT, { throwIfNoEntry: false }) ? walk(OUT, '.webp') : [])) {
  if (!wanted.has(webp)) { rmSync(webp); removed++; }
}

console.log(`[shot-variants] ${made} made, ${wanted.size - made} kept, ${removed} removed in ${((Date.now() - started) / 1000).toFixed(1)} s.`);
