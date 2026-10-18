# AéroCheck website

Marketing site for [AéroCheck](https://aerocheck.app) — a ground-up rebuild on **Astro** (static
output, hosted on GitHub Pages). Replaces the previous Jekyll site.

> Lives on the `website` branch of the AeroCheck repo. GitHub Pages is on the "GitHub Actions" source;
> `gh-pages`/Jekyll is fully retired. Deploys automatically on every push to `website` (see Deploy).

## Develop

```bash
npm install
npm run dev       # http://localhost:4321
npm run build     # static output → dist/
npm run preview   # serve the build locally
```

Requires Node 20.3+ / 22+.

## Editing content

The site speaks English (at `/`), German (`/de/`) and French (`/fr/`); the list, its order in the nav's switch and
each language's name and date format are in `src/lib/langs.ts`. A new language is its code there, its copy file, its
pages under `src/pages/<code>/`, its manual and privacy policy, and its entry in each component's copy table (typed by
`Lang`: a missing entry is a type error in the editor and a failed build). German is Swiss High German (Sie, ss, «…»).

All copy lives in **`src/data/en.yaml`**, **`src/data/de.yaml`** and **`src/data/fr.yaml`**. Top-level sections: `meta`,
`nav`, `hero`, `chapters` (the four-chapter strip), `flagship` (editorial feature rows, in
flight-narrative order), `phone`, `supporting` (compact grid), `ecosystem` (pills), `device_labels`,
`footer`. No code changes needed to reword features, reorder rows, or edit chips.

Screenshots are mapped in **`src/lib/shots.ts`** (one entry per screen key → iPad + iPhone image).
Images are real captures from the DEBUG scene injector (see `SCREENSHOTS.md`) under
`public/assets/screenshot/v6/`, recaptured after every app UI change that affects a shot; there is
no placeholder set active. Swap the paths in `shots.ts` to point at new captures — nothing else
changes.

## Aircraft requests

`/send` (the form), `/request` (a request's page), `/confirm` (the club's page) and `/clubs`, each with its
`/de/` and `/fr/` twins, talk from the browser to the intake worker (`intake.aerocheck.app`, AeroCheck-server's
`workers/intake/`), never to this site. The pages are in `src/components/requests/`, their scripts in
`src/scripts/requests/`, the copy in `src/lib/requests-copy.ts` (EN, FR) and `requests-copy.de.ts` (DE), and what the pages share with
the worker in `src/lib/intake.ts`:

- `INTAKE_URL`: the worker. A build with `PUBLIC_INTAKE_URL=http://localhost:8787` points the pages at a
  local `wrangler dev` instead (whose `ALLOWED_ORIGIN` must then be the local site).
- `TURNSTILE_SITE_KEY`: the site key of the aerocheck.app Turnstile widget (Cloudflare dashboard ›
  Turnstile). Empty, the form uses Cloudflare's always-pass test key on localhost and says "not open
  yet" anywhere else.

`/request` and `/confirm` open with a private link (`#t=<token>`, the part after `#` never reaches GitHub
Pages): they are `noindex` and left out of the sitemap.

## Design

Dark "glass cockpit" palette + editorial feature rows (see `src/styles/global.css` for tokens:
aviation gold `--gold`, green `--green`, monospace data labels). Components in `src/components/`:
`Hero` (auto-cycling device + iPad/iPhone toggle), `ChapterStrip`, `FeatureRow`, `FeatureGrid`,
`DevicePair` / `PhoneBand` (native-aspect device frames, never cropped), `Pills`, `Nav`, `Footer`,
plus the page-level `AircraftList`, `Changelog`, `Manual`, `Legal`, `Landing`, `PageStub`, `Icon`.
The iPad/iPhone toggle is global (persisted) and every device on the page follows it. Scroll-reveal
+ the hero cycle both respect `prefers-reduced-motion`.

## Deploy

`.github/workflows/deploy.yml` builds and deploys to Pages on every push to `website`, or via manual
dispatch. The app repo's `deploy-website-on-release.yml` also dispatches it whenever a GitHub release
is published/edited/deleted, so the changelog and footer version stay in sync with releases. The
`public/CNAME` (`aerocheck.app`) is preserved in the build output. `api.aerocheck.app` is a separate
Cloudflare Worker and is untouched by this site.
