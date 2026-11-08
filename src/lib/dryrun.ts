import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import type { Lang } from './langs';
import { dryRunImage, srcset } from './shots';

// The dry run in the browser (/dry-run, 7 Nov 2026): the app's guided flight, cut to the cards in
// src/data/dry-run/<lang>.json. Each file is written by the capture (SCREENSHOTS.md, "The dry run"): a card's own words, as
// the app shows them, and for each device its frame and the ring's place on it, in percent of the frame.
export interface Ring { x: number; y: number; width: number; height: number; }
export interface DryRunCard {
  id: string; part: number; partTitle: string; title: string; body: string;
  /** `act`: the visitor taps the ring. `look`: Next goes on. */
  kind: 'act' | 'look';
  ipad: { image: string; ring?: Ring };
  iphone: { image: string; ring?: Ring };
}

export function dryRunCards(lang: Lang): DryRunCard[] {
  return JSON.parse(readFileSync(join(process.cwd(), 'src', 'data', 'dry-run', `${lang}.json`), 'utf8'));
}

export function cardImage(path: string): { src: string; srcset: string | undefined } {
  const src = dryRunImage(path);
  return { src, srcset: srcset(src) };
}
