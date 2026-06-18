import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';
import icon from 'astro-icon';

// AéroCheck marketing site. Static output, served at aerocheck.app via GitHub Pages.
// Note: api.aerocheck.app is a separate Cloudflare Worker — this site never touches it.
export default defineConfig({
  site: 'https://aerocheck.app',
  trailingSlash: 'ignore',
  integrations: [icon(), sitemap()],
  i18n: {
    defaultLocale: 'en',
    locales: ['en', 'fr'],
    routing: { prefixDefaultLocale: false },
  },
  build: { assets: '_assets' },
});
