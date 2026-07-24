# AéroCheck website

Marketing site for [AéroCheck](https://aerocheck.app) — a ground-up rebuild on **Astro** (static
output, hosted on GitHub Pages). Replaces the previous Jekyll site.

> Lives on the `website` branch of the AeroCheck repo. The live site is still the Jekyll build on
> `gh-pages` until we flip GitHub Pages to "GitHub Actions" (see Deploy).

## Develop

```bash
npm install
npm run dev       # http://localhost:4321
npm run build     # static output → dist/
npm run preview   # serve the build locally
```

Requires Node 20.3+ / 22+.

## Editing content

All copy lives in **`src/data/en.yaml`** and **`src/data/fr.yaml`** — same idea as the old Jekyll
`_data/*.yml`. Sections: `meta`, `nav`, `hero`, `flagship` (the four editorial feature rows, in
flight-narrative order), `supporting` (compact grid), `ecosystem` (pills), `footer`. No code changes
needed to reword features, reorder rows, or edit chips.

Screenshots are mapped in **`src/lib/shots.ts`** (one entry per screen key → iPad + iPhone image).
The current images are **placeholders** (the v4 full-frame captures); they'll be replaced with
purpose-captured regions. Swap the paths there — nothing else changes.

## Design

Dark "glass cockpit" palette + editorial feature rows (see `src/styles/global.css` for tokens:
aviation gold `--gold`, green `--green`, monospace data labels). Components in `src/components/`:
`Hero` (auto-cycling device + iPad/iPhone toggle), `FeatureRow`, `DeviceFrame` (shows screenshots
at native aspect — never cropped), `FeatureGrid`, `Pills`, `Nav`, `Footer`. The iPad/iPhone toggle
is global (persisted) and every device on the page follows it. Scroll-reveal + the hero cycle both
respect `prefers-reduced-motion`.

## Deploy

`.github/workflows/deploy.yml` builds and deploys to Pages. It is **workflow_dispatch-only** until
GitHub Pages is switched to the "GitHub Actions" source (Settings → Pages). The `public/CNAME`
(`aerocheck.app`) is preserved in the build output. `api.aerocheck.app` is a separate Cloudflare
Worker and is untouched by this site.

## TODO (post-base)

- Replace placeholder screenshots with region captures (hero + 4 flagship rows).
- Build out sub-pages: Aircraft, Manual (EN/FR), Changelog, Privacy (currently stubs).
