import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';

// AéroCheck marketing site. Static output, served at aerocheck.app via GitHub Pages.
// Note: api.aerocheck.app is a separate Cloudflare Worker — this site may READ from it to populate
// pages (e.g. the live aircraft roster), but must NEVER modify it.
// Icons are hand-inlined in src/components/Icon.astro (DP9-WEB-03/06) — no astro-icon integration needed.
export default defineConfig({
  site: 'https://aerocheck.app',
  trailingSlash: 'ignore',
  integrations: [sitemap()],
  i18n: {
    defaultLocale: 'en',
    locales: ['en', 'fr'],
    routing: { prefixDefaultLocale: false },
  },
  build: { assets: '_assets' },
});
